class View

  attr_accessor :lu
  attr_accessor :lun
  attr_accessor :target_group
  attr_accessor :host_group

  def initialize(lu, lun, target_group, host_group)
    @lu = lu
    @lun = lun
    @target_group = target_group
    @host_group = host_group
  end

  def to_s
    "View: [ lu = #{@lu}" <<
        ", lun = " << (@lun.nil? ? "Auto" : @lun) <<
        ", target_group = " << (@target_group.nil? ? "All" : @target_group) <<
        ", host_group = " << (@host_group.nil? ? "All" : @host_group) << " ]"
  end
end