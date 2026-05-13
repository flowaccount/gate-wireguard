# frozen_string_literal: true

# Operational tasks for keeping the running WireGuard interface in sync with the
# Rails database. The day-to-day path (create/update/destroy a device) already
# triggers WireguardConfigGenerator.write_server_configuration, which now also
# calls `wg syncconf` automatically — these tasks are escape hatches.
namespace :wireguard do
  desc 'Audit DB vs /etc/wireguard/<iface>.conf vs running interface, report drift'
  task audit: :environment do
    cfg = VpnConfiguration.first or abort 'No VpnConfiguration row.'
    iface = cfg.wg_interface_name

    db_devices = VpnDevice.includes(:user, :ip_allocation).all
    db_ips = db_devices.map { |d| d.ip_allocation&.ip_address }.compact.to_set

    conf_path = "/etc/wireguard/#{iface}.conf"
    conf_ips  = if File.readable?(conf_path)
                  File.read(conf_path).scan(/AllowedIPs\s*=\s*(\d+\.\d+\.\d+\.\d+)\/32/).flatten.to_set
                else
                  warn "[audit] cannot read #{conf_path}"
                  Set.new
                end

    running_ips = `sudo -n wg show #{iface} allowed-ips 2>/dev/null`
                  .scan(/(\d+\.\d+\.\d+\.\d+)\/32/).flatten.to_set

    puts "interface=#{iface}"
    puts "db_devices=#{db_devices.size}  db_ips=#{db_ips.size}"
    puts "conf_peers=#{conf_ips.size}  running_peers=#{running_ips.size}"

    missing_from_conf = db_devices.reject { |d| d.ip_allocation && conf_ips.include?(d.ip_allocation.ip_address) }
    puts "\n== Devices in DB but missing from #{conf_path} (cannot connect): #{missing_from_conf.size} =="
    missing_from_conf.each do |d|
      puts "  id=#{d.id}  ip=#{d.ip_allocation&.ip_address}  user=#{d.user&.name.inspect}  device=#{d.description.inspect}  created=#{d.created_at}"
    end

    # Peers in the conf but not in the DB. These will be removed from the
    # conf (and the running kernel via `wg syncconf`) on the next regen.
    # If any of them are real users, re-create their device via the Rails
    # UI BEFORE running `rake wireguard:fix` — otherwise they'll lose
    # connectivity.
    ghosts = conf_ips - db_ips - Set[cfg.server_vpn_ip_address.to_s]
    puts "\n== Peers in conf but missing from DB (will be cleaned up on next regen): #{ghosts.size} =="
    if ghosts.any?
      puts "   ⚠  Review each one before running `rake wireguard:fix`."
      puts "      If a peer here represents a real user, re-add their device via the UI first."
    end
    ghosts.sort.each do |ip|
      # Try to find the "# User: ..." comment line that precedes this peer in the conf,
      # so the operator knows who the orphan was.
      comment = nil
      if File.readable?(conf_path)
        File.read(conf_path).lines.each_cons(3) do |a, _, c|
          comment = a.strip if c.include?("AllowedIPs = #{ip}/32") && a.start_with?('#')
        end
      end
      puts "  #{ip}   #{comment}"
    end

    kernel_drift = running_ips ^ conf_ips
    puts "\n== Running-interface vs conf drift: #{kernel_drift.size} =="
    kernel_drift.sort.each { |ip| puts "  #{ip}" }
  end

  desc 'Regenerate /etc/wireguard/<iface>.conf from DB and hot-reload (no session drops)'
  task regenerate: :environment do
    cfg = VpnConfiguration.first or abort 'No VpnConfiguration row.'
    puts "[regen] writing #{cfg.wg_interface_name}.conf for #{VpnDevice.count} devices"
    WireguardConfigGenerator.write_server_configuration(cfg)
    puts '[regen] done (write_server_configuration calls wg syncconf internally)'
  end

  desc 'One-shot fix: regen conf + sync running interface. Clears ghost peers, onboards new users.'
  task fix: %i[audit regenerate audit]
end
