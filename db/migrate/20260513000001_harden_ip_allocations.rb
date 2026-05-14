class HardenIpAllocations < ActiveRecord::Migration[7.1]
  # Adds the DB-level guarantees that the application has been relying on
  # at the model layer alone:
  #
  # 1. Unique index on ip_address  — closes the race window where two
  #    concurrent signups could both pass the `validates :uniqueness`
  #    check and double-allocate the same IP. With this index, the loser
  #    raises RecordNotUnique and IpAllocation.allocate_ip retries.
  #
  # 2. ON DELETE CASCADE on the vpn_device_id FK — guarantees that
  #    deleting a VpnDevice always frees its IP, even if the cascade is
  #    bypassed (raw SQL, manual cleanup, etc.). Previously the rule was
  #    only enforced by `dependent: :destroy` at the model layer.
  #
  # Before adding the unique index we proactively de-duplicate any IPs
  # that may have slipped through historically.
  def up
    say_with_time 'De-duplicating ip_allocations.ip_address before adding unique index' do
      duplicate_groups = IpAllocation
                         .group(:ip_address)
                         .having('COUNT(*) > 1')
                         .pluck(:ip_address)

      duplicate_groups.each do |ip|
        rows = IpAllocation.where(ip_address: ip).order(:id).to_a
        keep = rows.shift
        say "Keeping ip_allocation##{keep.id} (#{ip}), removing #{rows.size} duplicate(s)", true
        rows.each(&:destroy)
      end
    end

    add_index :ip_allocations, :ip_address, unique: true

    # Drop the old FK and re-add it with ON DELETE CASCADE.
    remove_foreign_key :ip_allocations, :vpn_devices
    add_foreign_key   :ip_allocations, :vpn_devices, on_delete: :cascade
  end

  def down
    remove_foreign_key :ip_allocations, :vpn_devices
    add_foreign_key   :ip_allocations, :vpn_devices

    remove_index :ip_allocations, :ip_address
  end
end
