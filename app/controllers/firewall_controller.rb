

class FirewallController < ApplicationController
  before_action :require_login
  before_action :get_iptables_rules, only: %i[show edit update destroy]
  # before_action :set_vpn_configuration, only: %i[ show update edit ]
  layout 'admin'

  def rules
    @iptables_output = get_iptables_rules
  end

  private

  def get_iptables_rules
    command = "sudo iptables -L -n -v --line-number"
    
    output, status = Open3.capture2e(command)
    
    if status.success?
      output # Return iptables output
    else
      "Error fetching iptables rules: #{stderr}" # Handle errors
    end
  end
end
