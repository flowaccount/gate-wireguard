require 'open3'

class FirewallController < ApplicationController
  before_action :require_login
  # before_action :set_vpn_configuration, only: %i[ show update edit ]
  layout 'admin'

  def rules
    @iptables_output = get_iptables_rules
  end

  private

  def get_iptables_rules
    command = "sudo iptables -L -n -v --line-number"
    
    stdout, stderr, status = Open3.capture3(command)
    
    if status.success?
      stdout # Return iptables output
    else
      "Error fetching iptables rules: #{stderr}" # Handle errors
    end
  end
end
