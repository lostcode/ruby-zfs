class LU
  attr_accessor :name

  def initialize(name)
    @name = name
  end

  def to_s
    "LU : " << @name
  end

  def delete
    cmd = [ZFS::STMFADM_PATH] + ["delete-lu", @name]

    out, status = Open3.capture2e(*cmd)

    if status.success?
      self
    else
      raise Exception, "something went wrong when deleting LU. output = #{out}"
    end
  end

  def exist?
    raise ZFS::InvalidName, "no argument to lu exist?" if @name.nil?

    cmd = [ZFS::STMFADM_PATH] + ["list-lu", @name]

    out, status = Open3.capture2e(*cmd)

    if status.success?
      true
    else
      false
    end
  end

  # get target group for this lu
  # currently, 1-1 relationship between lu and target group
  def get_tg
    raise ZFS::NotFound, "no such lu #{@name}" unless exist?

    cmd = [ZFS::STMFADM_PATH] + ["list-view", "-l", @name]
    out, status = Open3.capture2e(*cmd)
    if status.success?
      out.lines.collect do |line|
        if line.include? "Target Group"
          return TargetGroup.new(line.split[3])
        end
      end
    end
    nil
  end

  def add_view(lun, target_group, host_group)

    cmd = [ZFS::STMFADM_PATH] + ["add-view"]

    if ( !lun.nil? )
      cmd += ["-n", lun]
    end
    if ( !target_group.nil? )
      cmd += ["-t", target_group.name]
    end
    if ( !host_group.nil? )
      cmd += ["-h", host_group.name]
    end

    cmd += [@name]

    out, status = Open3.capture2e(*cmd)

    if status.success?
      self
    else
      raise Exception, "something went wrong when adding view. output = #{out}"
    end

    View.new(self, lun, target_group, host_group)
  end

end