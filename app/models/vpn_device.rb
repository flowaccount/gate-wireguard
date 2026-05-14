# This controllers takes care of VPN Decices
class VpnDevice < ApplicationRecord
  belongs_to :user
  has_one :ip_allocation, dependent: :destroy

  # Allocate an IP atomically with the device creation. If allocation fails
  # (pool exhausted, DB-level uniqueness collision after retries) the whole
  # transaction is rolled back so we never persist a device without an IP —
  # which would later cause `generate_peer_config` to crash on `nil.ip_address`
  # and leave wg0.conf half-written.
  after_create :assign_ip_allocation!

  def setup_device_with_keys
    @keys = WireguardConfigGenerator.generate_keys
    self.public_key = @keys[:public_key]
    self.private_key = @keys[:private_key]
  end

  def generate_qr_code
    qr = RQRCode::QRCode.new(WireguardConfigGenerator.generate_client_config(self, VpnConfiguration.all.first))
    qr.as_svg(
      offset: 0,
      color: '000',
      shape_rendering: 'crispEdges',
      module_size: 2,
      level: 1
    )
  end

  private

  def assign_ip_allocation!
    return if ip_allocation.present?

    allocation = IpAllocation.allocate_ip(self)
    if allocation.nil?
      errors.add(:base, 'No IP address available in the VPN pool')
      raise ActiveRecord::Rollback
    end
  end
end
