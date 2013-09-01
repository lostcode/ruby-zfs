# -*- mode: ruby; tab-width: 4; indent-tabs-mode: t -*-

require 'pathname'
require 'date'
require 'open3'
require 'target_group.rb'
require 'iscsi_target.rb'
require 'lu.rb'
require 'view.rb'

# Get ZFS object.
def ZFS(path)
  return path if path.is_a? ZFS

  path = Pathname(path).cleanpath.to_s

  if path.match(/^\//)
    ZFS.mounts[path]
  elsif path.match('@')
    ZFS::Snapshot.new(path)
  else
    ZFS::Filesystem.new(path)
  end
end

# Pathname-inspired class to handle ZFS filesystems/snapshots/volumes
class ZFS

  # constants
  STMFADM_PATH = "stmfadm"
  ITADM_PATH = "itadm"

  @zfs_path   = "zfs"
  @zpool_path = "zpool"
  @stmfadm_path = "stmfadm"

  attr_reader :name
  attr_reader :pool
  attr_reader :path

  class NotFound < Exception; end
  class AlreadyExists < Exception; end
  class InvalidName < Exception; end

  # Create a new ZFS object (_not_ filesystem).
  def initialize(name)
    @name, @pool, @path = name, *name.split('/', 2)
  end

  # Return the parent of the current filesystem, or nil if there is none.
  def parent
    p = Pathname(name).parent.to_s
    if p == '.'
      nil
    else
      ZFS(p)
    end
  end

  # Returns the children of this filesystem
  def children(opts={})
    raise NotFound if !exist?

    cmd = [ZFS.zfs_path].flatten + %w(list -H -r -oname -tfilesystem)
    cmd << '-d1' unless opts[:recursive]
    cmd << name

    stdout, stderr, status = Open3.capture3(*cmd)
    if status.success? and stderr == ""
      stdout.lines.drop(1).collect do |filesystem|
        ZFS(filesystem.chomp)
      end
    else
      raise Exception, "something went wrong"
    end
  end

  # Does the filesystem exist?
  def exist?
    cmd = [ZFS.zfs_path].flatten + %w(list -H -oname) + [name]

    out, status = Open3.capture2e(*cmd)
    if status.success? and out == "#{name}\n"
      true
    else
      false
    end
  end

  # Create filesystem
  def create(opts={})
    return nil if exist?

    cmd = [ZFS.zfs_path].flatten + ['create']
    cmd << '-p' if opts[:parents]
    cmd << '-s' if opts[:volume] and opts[:sparse]
    cmd += opts[:zfsopts].map{|el| ['-o', el]}.flatten if opts[:zfsopts]
    cmd += ['-V', opts[:volume]] if opts[:volume]
    cmd << name

    out, status = Open3.capture2e(*cmd)
    if status.success? and out.empty?
      return self
    elsif out.match(/dataset already exists\n$/)
      nil
    else
      raise Exception, "something went wrong: #{out}, #{status}"
    end
  end

  # Destroy filesystem
  def destroy!(opts={})
    raise NotFound if !exist?

    cmd = [ZFS.zfs_path].flatten + ['destroy']
    cmd << '-r' if opts[:children]
    cmd << name

    out, status = Open3.capture2e(*cmd)

    if status.success? and out.empty?
      return true
    else
      raise Exception, "something went wrong : out = #{out}"
    end
  end

  # Stringify
  def to_s
    "#<ZFS:#{name}>"
  end

  # ZFS's are considered equal if they are the same class and name
  def ==(other)
    other.class == self.class && other.name == self.name
  end

  def [](key)
    cmd = [ZFS.zfs_path].flatten + %w(get -ovalue -Hp) + [key.to_s, name]

    stdout, stderr, status = Open3.capture3(*cmd)

    if status.success? and stderr.empty? and stdout.lines.count == 1
      return stdout.chomp
    else
      raise Exception, "something went wrong"
    end
  end

  def []=(key, value)
    cmd = [ZFS.zfs_path].flatten + ['set', "#{key.to_s}=#{value}", name]

    out, status = Open3.capture2e(*cmd)

    if status.success? and out.empty?
      return value
    else
      raise Exception, "something went wrong: #{out}"
    end
  end

  class << self
    attr_accessor :zfs_path
    attr_accessor :zpool_path
    attr_accessor :stmfadm_path

    # Get an Array of all pools
    def pools
      cmd = [ZFS.zpool_path].flatten + %w(list -Honame)

      stdout, stderr, status = Open3.capture3(*cmd)

      if status.success? and stderr.empty?
        stdout.lines.collect do |pool|
          ZFS(pool.chomp)
        end
      else
        raise Exception, "something went wrong"
      end
    end

    # get an array of all logical units
    def logical_units
      logical_units = Array.new
      cmd = [ZFS::STMFADM_PATH] + ["list-lu"]
      out, status = Open3.capture2e(*cmd)
      if status.success?
        out.lines.collect do |lu|
          logical_units.push(lu.split[2])
        end
      else
        raise Exception, "something went wrong: out = #{out}"
      end
      logical_units
    end

    # Get a Hash of all mountpoints and their filesystems
    def mounts
      cmd = [ZFS.zfs_path].flatten + %w(get -rHp -oname,value mountpoint)

      stdout, stderr, status = Open3.capture3(*cmd)

      if status.success? and stderr.empty?
        mounts = stdout.lines.collect do |line|
          fs, path = line.chomp.split(/\t/, 2)
          [path, ZFS(fs)]
        end
        Hash[mounts]
      else
        raise Exception, "something went wrong"
      end
    end

    # Define an attribute
    def property(name, opts={})

      case opts[:type]
        when :size, :integer
          # FIXME: also takes :values. if :values is all-Integers, these are the only options. if there are non-ints, then :values is a supplement

          define_method name do
            Integer(self[name])
          end
          define_method "#{name}=" do |value|
            self[name] = value.to_s
          end if opts[:edit]

        when :boolean
          # FIXME: booleans can take extra values, so there are on/true, off/false, plus what amounts to an enum
          # FIXME: if options[:values] is defined, also create a 'name' method, since 'name?' might not ring true
          # FIXME: replace '_' by '-' in opts[:values]
          define_method "#{name}?" do
            self[name] == 'on'
          end
          define_method "#{name}=" do |value|
            self[name] = value ? 'on' : 'off'
          end if opts[:edit]

        when :enum
          define_method name do
            sym = (self[name] || "").gsub('-', '_').to_sym
            if opts[:values].grep(sym)
              return sym
            else
              raise "#{name} has value #{sym}, which is not in enum-list"
            end
          end
          define_method "#{name}=" do |value|
            self[name] = value.to_s.gsub('_', '-')
          end if opts[:edit]

        when :snapshot
          define_method name do
            val = self[name]
            if val.nil? or val == '-'
              nil
            else
              ZFS(val)
            end
          end

        when :float
          define_method name do
            Float(self[name])
          end
          define_method "#{name}=" do |value|
            self[name] = value
          end if opts[:edit]

        when :string
          define_method name do
            self[name]
          end
          define_method "#{name}=" do |value|
            self[name] = value
          end if opts[:edit]

        when :date
          define_method name do
            DateTime.strptime(self[name], '%s')
          end

        when :pathname
          define_method name do
            Pathname(self[name])
          end
          define_method "#{name}=" do |value|
            self[name] = value.to_s
          end if opts[:edit]

        else
          puts "Unknown type '#{opts[:type]}'"
      end
    end
    private :property
  end

  property :available,            type: :size
  property :compressratio,        type: :float
  property :creation,             type: :date
  property :defer_destroy,        type: :boolean
  property :mounted,              type: :boolean
  property :origin,               type: :snapshot
  property :refcompressratio,     type: :float
  property :referenced,           type: :size
  property :type,                 type: :enum, values: [:filesystem, :snapshot, :volume]
  property :used,                 type: :size
  property :usedbychildren,       type: :size
  property :usedbydataset,        type: :size
  property :usedbyrefreservation, type: :size
  property :usedbysnapshots,      type: :size
  property :userrefs,             type: :integer

  property :aclinherit,           type: :enum,    edit: true, inherit: true, values: [:discard, :noallow, :restricted, :passthrough, :passthrough_x]
  property :atime,                type: :boolean, edit: true, inherit: true
  property :canmount,             type: :boolean, edit: true,                values: [:noauto]
  property :checksum,             type: :boolean, edit: true, inherit: true, values: [:fletcher2, :fletcher4, :sha256]
  property :compression,          type: :boolean, edit: true, inherit: true, values: [:lzjb, :gzip, :gzip_1, :gzip_2, :gzip_3, :gzip_4, :gzip_5, :gzip_6, :gzip_7, :gzip_8, :gzip_9, :zle]
  property :copies,               type: :integer, edit: true, inherit: true, values: [1, 2, 3]
  property :dedup,                type: :boolean, edit: true, inherit: true, values: [:verify, :sha256, 'sha256,verify']
  property :devices,              type: :boolean, edit: true, inherit: true
  property :exec,                 type: :boolean, edit: true, inherit: true
  property :logbias,              type: :enum,    edit: true, inherit: true, values: [:latency, :throughput]
  property :mlslabel,             type: :string,  edit: true, inherit: true
  property :mountpoint,           type: :pathname,edit: true, inherit: true
  property :nbmand,               type: :boolean, edit: true, inherit: true
  property :primarycache,         type: :enum,    edit: true, inherit: true, values: [:all, :none, :metadata]
  property :quota,                type: :size,    edit: true,                values: [:none]
  property :readonly,             type: :boolean, edit: true, inherit: true
  property :recordsize,           type: :integer, edit: true, inherit: true, values: [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072]
  property :refquota,             type: :size,    edit: true,                values: [:none]
  property :refreservation,       type: :size,    edit: true,                values: [:none]
  property :reservation,          type: :size,    edit: true,                values: [:none]
  property :secondarycache,       type: :enum,    edit: true, inherit: true, values: [:all, :none, :metadata]
  property :setuid,               type: :boolean, edit: true, inherit: true
  property :sharenfs,             type: :boolean, edit: true, inherit: true # FIXME: also takes 'share(1M) options'
  property :sharesmb,             type: :boolean, edit: true, inherit: true # FIXME: also takes 'sharemgr(1M) options'
  property :snapdir,              type: :enum,    edit: true, inherit: true, values: [:hidden, :visible]
  property :sync,                 type: :enum,    edit: true, inherit: true, values: [:standard, :always, :disabled]
  property :version,              type: :integer, edit: true,                values: [1, 2, 3, 4, :current]
  property :vscan,                type: :boolean, edit: true, inherit: true
  property :xattr,                type: :boolean, edit: true, inherit: true
  property :zoned,                type: :boolean, edit: true, inherit: true
  property :jailed,               type: :boolean, edit: true, inherit: true
  property :volsize,              type: :size,    edit: true

  property :casesensitivity,      type: :enum,    create_only: true, values: [:sensitive, :insensitive, :mixed]
  property :normalization,        type: :enum,    create_only: true, values: [:none, :formC, :formD, :formKC, :formKD]
  property :utf8only,             type: :boolean, create_only: true
  property :volblocksize,         type: :integer, create_only: true, values: [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072]
end


class ZFS::Snapshot < ZFS
  # Return sub-filesystem
  def +(path)
    raise InvalidName if path.match(/@/)

    parent + path + name.sub(/^.+@/, '@')
  end

  # Just remove the snapshot-name
  def parent
    ZFS(name.sub(/@.+/, ''))
  end

  # Rename snapshot
  def rename!(newname, opts={})
    raise AlreadyExists if (parent + "@#{newname}").exist?

    newname = (parent + "@#{newname}").name

    cmd = [ZFS.zfs_path].flatten + ['rename']
    cmd << '-r' if opts[:children]
    cmd << name
    cmd << newname

    out, status = Open3.capture2e(*cmd)

    if status.success? and out.empty?
      initialize(newname)
      return self
    else
      raise Exception, "something went wrong"
    end
  end

  # Clone snapshot
  def clone!(clone, opts={})
    clone = clone.name if clone.is_a? ZFS

    raise AlreadyExists if ZFS(clone).exist?

    cmd = [ZFS.zfs_path].flatten + ['clone']
    cmd << '-p' if opts[:parents]
    cmd << name
    cmd << clone

    out, status = Open3.capture2e(*cmd)

    if status.success? and out.empty?
      return ZFS(clone)
    else
      raise Exception, "something went wrong: out = #{out}"
    end
  end

  # Send snapshot to another filesystem
  def send_to(dest, opts={})
    incr_snap = nil
    dest = ZFS(dest)

    if opts[:incremental] and opts[:intermediary]
      raise ArgumentError, "can't specify both :incremental and :intermediary"
    end

    incr_snap = opts[:incremental] || opts[:intermediary]
    if incr_snap
      if incr_snap.is_a? String and incr_snap.match(/^@/)
        incr_snap = self.parent + incr_snap
      else
        incr_snap = ZFS(incr_snap)
        raise ArgumentError, "incremental snapshot must be in the same filesystem as #{self}" if incr_snap.parent != self.parent
      end

      snapname = incr_snap.name.sub(/^.+@/, '@')

      raise NotFound, "destination must already exist when receiving incremental stream" unless dest.exist?
      raise NotFound, "snapshot #{snapname} must exist at #{self.parent}" if self.parent.snapshots.grep(incr_snap).empty?
      raise NotFound, "snapshot #{snapname} must exist at #{dest}" if dest.snapshots.grep(dest + snapname).empty?
    elsif opts[:use_sent_name]
      raise NotFound, "destination must already exist when using sent name" unless dest.exist?
    elsif dest.exist?
      raise AlreadyExists, "destination must not exist when receiving full stream"
    end

    dest = dest.name if dest.is_a? ZFS
    incr_snap = incr_snap.name if incr_snap.is_a? ZFS

    send_opts = ZFS.zfs_path.flatten + ['send']
    send_opts.concat ['-i', incr_snap] if opts[:incremental]
    send_opts.concat ['-I', incr_snap] if opts[:intermediary]
    send_opts << '-R' if opts[:replication]
    send_opts << name

    receive_opts = ZFS.zfs_path.flatten + ['receive']
    receive_opts << '-d' if opts[:use_sent_name]
    receive_opts << dest

    Open3.popen3(*receive_opts) do |rstdin, rstdout, rstderr, rthr|
      Open3.popen3(*send_opts) do |sstdin, sstdout, sstderr, sthr|
        while !sstdout.eof?
          rstdin.write(sstdout.read(16384))
        end
        raise "stink" unless sstderr.read == ''
      end
    end
  end
end


class ZFS::Filesystem < ZFS
  # Return sub-filesystem.
  def +(path)
    if path.match(/^@/)
      ZFS("#{name.to_s}#{path}")
    else
      path = Pathname(name) + path
      ZFS(path.cleanpath.to_s)
    end
  end

  # Rename filesystem.
  def rename!(newname, opts={})
    raise AlreadyExists if ZFS(newname).exist?

    cmd = [ZFS.zfs_path].flatten + ['rename']
    cmd << '-p' if opts[:parents]
    cmd << name
    cmd << newname

    out, status = Open3.capture2e(*cmd)

    if status.success? and out.empty?
      initialize(newname)
      return self
    else
      raise Exception, "something went wrong: out = #{out}"
    end
  end

  # Create a snapshot.
  def snapshot(snapname, opts={})
    raise NotFound, "no such filesystem" if !exist?
    raise AlreadyExists, "#{snapname} exists" if ZFS("#{name}@#{snapname}").exist?

    cmd = [ZFS.zfs_path].flatten + ['snapshot']
    cmd << '-r' if opts[:children]
    cmd << "#{name}@#{snapname}"

    out, status = Open3.capture2e(*cmd)

    if status.success? and out.empty?
      return ZFS("#{name}@#{snapname}")
    else
      raise Exception, "something went wrong: out = #{out}"
    end
  end

  # Get an Array of all snapshots on this filesystem.
  def snapshots
    raise NotFound, "no such filesystem" if !exist?

    stdout, stderr = [], []
    cmd = [ZFS.zfs_path].flatten + %w(list -H -d1 -r -oname -tsnapshot) + [name]

    stdout, stderr, status = Open3.capture3(*cmd)

    if status.success? and stderr.empty?
      stdout.lines.collect do |snap|
        ZFS(snap.chomp)
      end
    else
      raise Exception, "something went wrong"
    end
  end

  # Promote this filesystem.
  def promote!
    raise NotFound, "filesystem is not a clone" if self.origin.nil?

    cmd = [ZFS.zfs_path].flatten + ['promote', name]

    out, status = Open3.capture2e(*cmd)

    if status.success? and out.empty?
      return self
    else
      raise Exception, "something went wrong: out = #{out}"
    end
  end

  # create a logical unit for this file system
  # return the lu number
  def createlu()
    raise NotFound, "no such filesystem" if !exist?

    cmd = [ZFS.stmfadm_path].flatten + ['create-lu', "/dev/zvol/dsk/" + name]

    out, status = Open3.capture2e(*cmd)

    if out.empty?
      raise Exception, "no return message from create-lu"
    end

    if status.success?
      return LU.new(out.split[3])
    elsif out.empty?
      raise Exception, "no return message from create-lu"
    else
      raise Exception, "something went wrong: out = #{out}"
    end
  end
end
