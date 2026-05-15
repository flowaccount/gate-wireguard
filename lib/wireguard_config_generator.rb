require 'open3'
require 'tempfile'
# WireGuard config generator, this expects you to have wg utility installed on the same box for generating keys
class WireguardConfigGenerator
  # Only interface names that match this pattern are allowed to be passed to shell-outs.
  SAFE_INTERFACE_NAME = /\A[A-Za-z0-9_-]{1,15}\z/.freeze

  class << self
    def generate_server_config # rubocop:disable Metrics/MethodLength
      keys = generate_keys

      {
        private_key: keys[:private_key],
        public_key: keys[:public_key],
        endpoint: '',
        port: 51_820, # This is the default port for WireGuard
        range: '10.42.5.0', # This is the default range for WireGuard
        interface_name: 'wg0', # This is the default interface name for WireGuard
        keep_alive: '25', # This is the default keep alive for WireGuard
        forward_interface: 'eth0' # This is the default forward interface for WireGuard
      }
    end

    def generate_client_config(client, vpn_configuration)
      allowed_ips = vpn_configuration.network_addresses.map(&:network_address).join(', ')

      # config = "# User: #{client.user.name}, Device: #{client.description}\n"
      # config += "[Interface]\n"
      config = "[Interface]\n"
      config += "PrivateKey = #{client.private_key}\n"
      config += "Address = #{client.ip_allocation.ip_address}/24\n"
      config += "DNS = #{vpn_configuration.dns_servers}\n\n" if vpn_configuration.dns_servers.present?

      config += "[Peer]\n"
      config += "PublicKey = #{vpn_configuration.wg_public_key}\n"
      config += "Endpoint = #{vpn_configuration.wg_ip_address}:#{vpn_configuration.wg_port}\n"
      #config += "AllowedIPs = 0.0.0.0/0\n"
      config += "AllowedIPs = #{vpn_configuration.server_vpn_ip_address}/32\n"
      vpn_configuration.network_addresses.each do |ip_address|
        config += "AllowedIPs = #{ip_address.network_address}\n"
      end
      #PersistentKeepalive 40second
      #config += "PersistentKeepalive = 40\n" if vpn_configuration.wg_keep_alive.present?
      config += "\n"

      config
    end

    def generate_keys
      private_key = Open3.capture2('wg genkey')[0].strip
      public_key = Open3.capture2('wg pubkey', stdin_data: private_key)[0].strip
      {
        private_key: private_key,
        public_key: public_key
      }
    end

    def write_server_configuration(vpn_configuration)
      config_dir = Rails.root.join('config', 'wireguard')
      FileUtils.mkdir_p(config_dir)
      interface_name = vpn_configuration.wg_interface_name
      config_file = config_dir.join("#{interface_name}.conf")
      # Write atomically so the kernel (which reads via the
      # /etc/wireguard/wg0.conf -> config/wireguard/wg0.conf symlink) never
      # sees a half-written file.
      tmp_path = "#{config_file}.tmp"
      File.write(tmp_path, generate_config(vpn_configuration))
      File.rename(tmp_path, config_file)
      # File.write creates the tmp file with default umask (typically 0644),
      # which `wg-quick` warns about ("conf is world accessible"). Force
      # 0600 so the warning never triggers and so the server private key
      # is never group/other-readable.
      File.chmod(0o600, config_file)

      private_key_file = config_dir.join('private.key')
      File.write(private_key_file, vpn_configuration.wg_private_key)
      File.chmod(0o600, private_key_file)

      public_key_file = config_dir.join('public.key')
      File.write(public_key_file, vpn_configuration.wg_public_key)

      # Hot-reload the interface in-place. Unlike `systemctl restart wg-quick@wg0`
      # (which deletes the link and drops every active session), `wg syncconf`
      # reconciles peers atomically: new peers are added, removed peers are
      # dropped, existing peers keep their handshake state.
      reload_wireguard(interface_name)
    end

    # Hot-reloads the running WireGuard interface from /etc/wireguard/<iface>.conf
    # without tearing down existing sessions.
    #
    # Equivalent to: `wg syncconf wg0 <(wg-quick strip wg0)`
    # Returns true on success, false otherwise. Never raises — failure is logged
    # so the caller (an after_action) can't break the HTTP response.
    def reload_wireguard(interface_name)
      unless interface_name.to_s.match?(SAFE_INTERFACE_NAME)
        Rails.logger.error("[wg-reload] refusing to reload unsafe interface name: #{interface_name.inspect}")
        return false
      end

      # Use `capture2` (stdout only), NOT `capture2e` — wg-quick writes
      # informational warnings ("conf is world accessible", etc.) to stderr.
      # If we capture stderr alongside stdout and pipe the combined output
      # into `wg syncconf`, the warning text gets parsed as a config line
      # and syncconf rejects the whole file with "Line unrecognized: `Warning:..."
      stripped, strip_status = Open3.capture2('sudo', '-n', 'wg-quick', 'strip', interface_name)
      unless strip_status.success?
        Rails.logger.error("[wg-reload] wg-quick strip #{interface_name} failed (exit=#{strip_status.exitstatus})")
        return false
      end

      Tempfile.create(["wg-#{interface_name}-", '.conf']) do |f|
        f.write(stripped)
        f.flush
        File.chmod(0o600, f.path)
        # capture2 here as well — kernel-side wg might emit informational
        # warnings on stderr that we don't want to log as errors.
        out, sync_status = Open3.capture2e('sudo', '-n', 'wg', 'syncconf', interface_name, f.path)
        unless sync_status.success?
          Rails.logger.error("[wg-reload] wg syncconf #{interface_name} failed: #{out}")
          return false
        end
      end
      Rails.logger.info("[wg-reload] #{interface_name} synced")
      true
    rescue StandardError => e
      Rails.logger.error("[wg-reload] unexpected error: #{e.class}: #{e.message}")
      false
    end

    def generate_config(vpn_configuration)
      config = "[Interface]\n"
      config += "PrivateKey = #{vpn_configuration.wg_private_key}\n"
      config += "ListenPort = #{vpn_configuration.wg_port}\n"
      config += "Address = #{vpn_configuration.server_vpn_ip_address}/24 \n\n"

      VpnDevice.all.each do |client|
        config += generate_peer_config(client, vpn_configuration)
      end

      config
    end

    private

    def generate_peer_config(client, vpn_configuration)
      peer_config = "# User: #{client.user.name}, Device: #{client.description}\n"
      peer_config += "[Peer]\n"
      peer_config += "PublicKey = #{client.public_key}\n"
      peer_config += "AllowedIPs = #{client.ip_allocation.ip_address}/32\n"
      #vpn_configuration.network_addresses.each do |ip_address|
       # peer_config += "AllowedIPs = #{ip_address.network_address}\n"
      #end
      peer_config += "# Optionally, add a PersistentKeepalive for NAT traversal\n"
      peer_config += "PersistentKeepalive = 25\n" if vpn_configuration.wg_keep_alive.present?
      peer_config += "\n\n"
      peer_config
    end
  end
end
