

class FirewallsController < ApplicationController
  before_action :require_login
  # before_action :get_iptables_rules, only: %i[show edit update destroy]
  # before_action :set_vpn_configuration, only: %i[ show update edit ]
  layout 'admin'

  def index
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
      flash[:notice] = "Add Allowed IP Address: #{@firewall.name}"
      render js: "window.location.reload();"  # Refresh page after success
    else
      render :index, alert: "Failed to create WireGuard interface:\n#{output}"
    end
  end

  def update_display_rules
    name = params[:name]
    
    if name
      @allowed_ips_output = get_allowed_ip_addresses(name)
      # Handle active status logic here
      #render json: { message: 'Status is active' }, status: :ok
    else
      # Handle inactive status logic here
      #render json: { message: 'Status is inactive' }, status: :ok
    end
  end

  private

  def firewall_params
    params.require(:firewall).permit(:name, :ipAddress)
  end

  def get_allowed_ip_addresses(name)
    command = "sudo ipset list #{name} | awk 'NR > 7 { print $1 }'"
    
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
