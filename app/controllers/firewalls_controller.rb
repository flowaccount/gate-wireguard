

class FirewallsController < ApplicationController
  before_action :require_login
  # before_action :get_iptables_rules, only: %i[show edit update destroy]
  # before_action :set_vpn_configuration, only: %i[ show update edit ]
  layout 'admin'

  def index
    @allowed_ips_output = get_allowed_ip_addresses
    @firewall = Firewall.new
  end

  def rules
    @iptables_output = get_iptables_rules
  end

  def new
    @firewall = Firewall.new
  end

  # Handle form submission
  def create
    @firewall = Firewall.new(firewall_params)
    output, status = Open3.capture2e("sudo ipset add #{@firewall.name} #{@firewall.ipAddress}")
    if status.success?
      redirect_to firewalls_index_path, notice: 'WireGuard interface created successfully.'
    else
      render :index, alert: "Failed to create WireGuard interface:\n#{output}"
    end
  end

  private

  def firewall_params
    params.require(:firewall).permit(:name, :ipAddress)
  end

  def get_allowed_ip_addresses
    command = "sudo ipset list allowed_remotes"
    
    output, status = Open3.capture2e(command)
    
    if status.success?
      output # Return iptables output
    else
      "Error fetching iptables rules: #{stderr}" # Handle errors
    end
  end

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
