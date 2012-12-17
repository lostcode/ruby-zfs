require 'open3'

class IscsiTarget

  attr_accessor :name

  # initialize iscsi target object with name
  # name can be nil to signify no particular inclination in target naming
  def initialize(name)
    @name = name
  end

  def to_s
    "iscsi target : " << @name
  end

  def exist?
    raise ZFS::InvalidName, "no argument to iscsi target exist?" if @name.nil?

    cmd = [ZFS::ITADM_PATH] + ["list-target", @name]

    out, status = Open3.capture2e(*cmd)

    if status.success?
      true
    else
      false
    end
  end

  def create
    raise ZFS::AlreadyExists, "target group already exists" if !@name.nil? && exist?

    cmd = [ZFS::ITADM_PATH, "create-target"] + (!@name.nil? ? [@name] : [])

    out, status = Open3.capture2e(*cmd)

    if status.success?
      # init name
      @name = out.split[1]
      self
    else
      raise Exception, "something went wrong when creating iscsi target. output = #{out}"
    end
  end

  def delete
    raise ZFS::InvalidName, "no name for iscsi target" if @name.nil?
    raise ZFS::NotFound, "no such iscsi target" if !exist?

    cmd = [ZFS::ITADM_PATH] + ["delete-target", @name]

    out, status = Open3.capture2e(*cmd)

    if status.success?
      self
    else
      raise Exception, "something went wrong when deleting iscsi target. output = #{out}"
    end
  end

  def go_offline
    raise ZFS::InvalidName, "no name for iscsi target" if @name.nil?
    raise ZFS::NotFound, "no such iscsi target" if !exist?

    cmd = [ZFS::STMFADM_PATH] + ["offline-target", @name]

    out, status = Open3.capture2e(*cmd)

    if status.success?
      self
    else
      raise Exception, "something went wrong when taking iscsi target offline. output = #{out}"
    end
  end

  def go_online
    raise ZFS::InvalidName, "no name for iscsi target" if @name.nil?
    raise ZFS::NotFound, "no such iscsi target" if !exist?

    cmd = [ZFS::STMFADM_PATH] + ["online-target", @name]

    out, status = Open3.capture2e(*cmd)

    if status.success?
      self
    else
      raise Exception, "something went wrong when taking iscsi target online. output = #{out}"
    end
  end

end