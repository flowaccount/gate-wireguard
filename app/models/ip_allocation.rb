# Purpose: Model for IP Allocation. This model is used to store the IP address allocated to a VPN device.
class IpAllocation < ApplicationRecord
  validates :ip_address, presence: true, uniqueness: true
  belongs_to :vpn_device

  # Full /24 host range (.1 is the WG server itself).
  #
  # History: this range was previously narrowed to (140..254) as a workaround
  # because deletes weren't propagating from the Rails DB to the running
  # WireGuard kernel — the conf file got rewritten but the kernel was never
  # told to drop the peer. That left "phantom" peers in the kernel and
  # forced new allocations into the .140-.254 range to avoid IP collision
  # when the same IP got reassigned to a new user.
  #
  # Fixed by adding `WireguardConfigGenerator.reload_wireguard` (wg syncconf)
  # to the destroy after_action — the kernel now reliably reconciles with
  # the conf on every change. With reliable delete propagation, the full
  # range is safe to reopen.
  ALLOCATION_RANGE = (2..254).freeze

  # Number of times to retry allocation when another transaction races us to
  # the same IP and the DB-level unique index rejects our insert. The DB
  # uniqueness constraint is added by migration 20260513000001.
  ALLOCATION_RETRIES = 5

  def self.next_available_ip
    base = get_base_ip
    return nil if base.nil?

    taken = IpAllocation.pluck(:ip_address).to_set
    ALLOCATION_RANGE.each do |i|
      ip = "#{base}.#{i}"
      return ip unless taken.include?(ip)
    end
    nil # Range exhausted
  end

  def self.get_base_ip
    vpn_configuration = VpnConfiguration.all.first
    return nil if vpn_configuration.nil? || vpn_configuration.wg_ip_range.blank?

    vpn_configuration.wg_ip_range.split('.')[0..2].join('.')
  end

  # Allocate the next free IP to a device. Retries on RecordNotUnique so two
  # concurrent signups can't both win on the same IP — whichever loses the
  # uniqueness race simply picks the next free address.
  #
  # Returns the created IpAllocation, or nil if the pool is exhausted /
  # the race could not be resolved within ALLOCATION_RETRIES attempts.
  def self.allocate_ip(vpn_device)
    attempts = 0
    begin
      attempts += 1
      ip = next_available_ip
      return nil unless ip

      transaction(requires_new: true) do
        return IpAllocation.create!(vpn_device: vpn_device, ip_address: ip)
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      retry if attempts < ALLOCATION_RETRIES
      Rails.logger.error("[IpAllocation] giving up after #{attempts} attempts: #{e.message}")
      nil
    end
  end

  def self.deallocate_ip(vpn_device)
    IpAllocation.where(vpn_device: vpn_device).destroy_all
  end
end
