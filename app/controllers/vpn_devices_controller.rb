class VpnDevicesController < ApplicationController
  before_action :set_vpn_device, only: %i[show edit update destroy]
  before_action :require_login
  # NOTE: `:new` and `:add_with_user` are both actions that PERSIST a VpnDevice
  # (this controller has a non-standard pattern where GET `#new` and POST-style
  # `#add_with_user` both save records). They MUST be in the after_action list,
  # otherwise newly registered peers never make it into wg0.conf — which is
  # why the service has been needing manual `systemctl restart wg-quick@wg0`
  # every time a user signed up.
  after_action :update_wireguard_config, only: %i[new add_with_user update destroy]
  layout 'admin'

  # GET /vpn_devices or /vpn_devices.json
  def index
    @nodes = true if params['nodes'].present?
    @vpn_devices = if @nodes == true
                     # find vpn devices where node variable is true
                     VpnDevice.where(node: true)
                   else
                     VpnDevice.all
                   end
  end

  # GET /vpn_devices/1 or /vpn_devices/1.json
  def show
    @nodes = true if params['nodes'].present?
    if @vpn_device.description.nil? || @vpn_device.description.empty?
      redirect_to root_path, alert: 'Vpn device description is empty.'
    end
    @vpn_configuration = VpnConfiguration.all.first
  end

  def download_config
    @vpn_device = VpnDevice.find(params[:id])
    config_content = WireguardConfigGenerator.generate_client_config(@vpn_device, VpnConfiguration.first)
    send_data config_content, filename: 'gate_vpn_config.conf'
  end

  # Idempotency window for #new and #add_with_user. If the same target user
  # had a device created within this many seconds, we short-circuit and return
  # that device instead of persisting another one. Protects against:
  #   - Turbo Drive prefetch on hover (issues a background GET, then another on click)
  #   - Browser pre-rendering / link prefetch
  #   - Double-click / rapid double-submit
  #   - Refresh-after-create
  # Evidence: prior to this guard, 16+ users had duplicate devices created
  # within sub-second windows (logs showed deltas as low as 0.2s).
  IDEMPOTENCY_WINDOW = 30.seconds

  # GET /vpn_devices/new
  #
  # NOTE: this controller's `#new` is a GET that persists a record (preserved
  # for compatibility with the existing client flow — proper REST refactor is
  # out of scope). Idempotency protection is enforced via the recent-device
  # check below; IP allocation is transactional via VpnDevice's after_create
  # callback (rolls back the device if the pool is exhausted).
  def new
    if (recent = recent_device_for(current_user))
      redirect_to root_path, notice: 'You already have a recently created device.'
      return
    end

    @vpn_device = current_user.vpn_devices.build
    @vpn_device.setup_device_with_keys

    respond_to do |format|
      if @vpn_device.save
        format.html { redirect_to root_path, notice: 'Vpn device was successfully created.' }
        format.json { render :show, status: :ok, location: @vpn_device }
      else
        format.html { redirect_to root_path, alert: "Could not create device: #{@vpn_device.errors.full_messages.to_sentence}" }
        format.json { render json: @vpn_device.errors, status: :unprocessable_entity }
      end
    end
  end


  # Admin flow: create a VPN device on behalf of another user.
  # IP allocation is handled in VpnDevice's after_create callback (transactional).
  # Same idempotency window applies — the admin form is also vulnerable to
  # double-submit / prefetch even though POST requests are not prefetched by
  # Turbo. We err on the side of safety.
  def add_with_user
    @user = User.find(params[:userId])

    if (recent = recent_device_for(@user))
      redirect_to root_path, notice: 'User already has a recently created device.'
      return
    end

    @vpn_device = @user.vpn_devices.build
    @vpn_device.description = params[:description]
    @vpn_device.setup_device_with_keys
    respond_to do |format|
      if @vpn_device.save
        format.html { redirect_to root_path, notice: 'Vpn device was successfully created.' }
        format.json { render :show, status: :ok, location: @vpn_device }
      else
        format.html { redirect_to root_path, alert: "Could not create device: #{@vpn_device.errors.full_messages.to_sentence}" }
        format.json { render json: @vpn_device.errors, status: :unprocessable_entity }
      end
    end
  end


  # POST /vpn_devices or /vpn_devices.json
  def create
    config_file = params[:config_file]
    output, status = Open3.capture2e("sudo wg-quick up #{config_file}")   
    if status.success?
      redirect_to vpn_devices_path, notice: 'WireGuard interface created successfully.'
    else
      redirect_to new_vpn_device_path, alert: "Failed to create WireGuard interface:\n#{output}"
    end
  end

  # PATCH/PUT /vpn_devices/1 or /vpn_devices/1.json
  def update
    respond_to do |format|
      if @vpn_device.update(vpn_device_params)
        format.html { redirect_to root_path, notice: 'Vpn device was successfully updated.' }
        format.json { render :show, status: :ok, location: @vpn_device }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @vpn_device.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /vpn_devices/1 or /vpn_devices/1.json
  def destroy
    @vpn_device.destroy!
    respond_to do |format|
      format.html { redirect_to root_path, notice: 'Vpn device was successfully destroyed.' }
      format.json { head :no_content }
    end
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_vpn_device
    @vpn_device = VpnDevice.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def vpn_device_params
    params.require(:vpn_device).permit(:user_id, :description, :private_key, :public_key, :node)
  end

  def update_wireguard_config
    WireguardConfigGenerator.write_server_configuration(VpnConfiguration.first)
  end

  # Returns the most recent VpnDevice the given user created within the
  # idempotency window, or nil. Used to short-circuit duplicate creates
  # caused by browser prefetch / double-submit. See IDEMPOTENCY_WINDOW.
  def recent_device_for(user)
    return nil if user.nil?

    user.vpn_devices
        .where('created_at > ?', IDEMPOTENCY_WINDOW.ago)
        .order(created_at: :desc)
        .first
  end
end
