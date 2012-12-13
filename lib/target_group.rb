require 'pathname'
require 'open3'

class TargetGroup

  attr_accessor :name

  def initialize(name)
    @name = name
  end

  def to_s
    "target group : " << @name
  end

  def exist?
    cmd = [ZFS::STMFADM_PATH] + ["list-tg", name]

    out, status = Open3.capture2e(*cmd)

    if status.success? and out.split[2] == name
      true
    else
      false
    end
  end

  def create
    raise ZFS::AlreadyExists, "target group already exists" if exist?

    cmd = [ZFS::STMFADM_PATH, "create-tg", @name]

    out, status = Open3.capture2e(*cmd)

    if status.success? and out.empty?
      self
    else
      raise Exception, "something went wrong when creating target group. output = #{out}"
    end
  end

  def delete
    raise ZFS::NotFound, "no such target group" if !exist?

    cmd = [ZFS::STMFADM_PATH] + ["delete-tg", @name]

    out, status = Open3.capture2e(*cmd)

    if status.success?
      self
    else
      raise Exception, "something went wrong when deleting target group. output = #{out}"
    end
  end

  def add_member(target)
    raise ZFS::NotFound, "no such target group" if !exist?
    raise ZFS::NotFound, "no such iscsi target" if !target.exist?

    cmd = [ZFS::STMFADM_PATH, "add-tg-member", "-g", @name, target.name]

    out, status = Open3.capture2e(*cmd)

    if status.success? and out.empty?
      self
    else
      raise Exception, "something went wrong when creating target group. output = #{out}"
    end

  end

end
