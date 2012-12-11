require 'pathname'
require 'open3'

class TargetGroup

  STMFADM_PATH = "stmfadm"

  attr_accessor :name

  def initialize(name)
    @name = name
  end

  def to_s
    "target group : " << name
  end

  def exist?
    cmd = [STMFADM_PATH] + ["list-tg", name]

    out, status = Open3.capture2e(*cmd)

    if status.success? and out == "#{name}\n"
      true
    else
      false
    end
  end

  def create()

  end
end
