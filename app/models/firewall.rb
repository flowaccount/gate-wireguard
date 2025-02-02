# app/models/firewall.rb
class Firewall 
    include ActiveModel::Model
    # model code
    attr_accessor :name, :ipAddress

    def initialize(name:, ipAddress:)
        @name = name
        @ipAddress = ipAddress
    end
end
  