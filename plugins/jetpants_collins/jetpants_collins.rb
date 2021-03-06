require 'collins_client'

# Entrypoint for jetpants_collins plugin (namespace Jetpants::Plugin::JetCollins),
# which offers integration with the Collins hardware asset tracking system.
# This particular file accomplishes the following:
#
#   * Provides a JetCollins mixin module. Any class including this should also
#     implement a collins_asset method to convert objects to Collins assets;
#     the class can then use the provided collins_get and collins_set wrappers,
#     along with the collins_attr_accessor class method.
#
#   * Jetpants::Plugin::JetCollins can also be used as a global Collins API
#     client -- the module itself will delegate all missing methods to a 
#     Collins::Client object.
#
#   * Loads monkeypatches for Jetpants classes DB, Host, Pool, Shard, Topology,
#     and Collins class Asset.
#
# Configuration options in Jetpants config file include:
#   user          =>  collins account username (required)
#   password      =>  collins account password (required)
#   url           =>  collins URL (required)
#   timeout       =>  collins client timeout, in seconds (default: 30)
#   datacenter    =>  collins data center name that we're running Jetpants in the context of (required if multi-datacenter)
#   remote_lookup =>  if true, supply remoteLookup parameter to search multiple datacenters (default: false)


module Jetpants
  module Plugin
    module JetCollins
      @collins_service = nil
      
      ##### CLASS METHODS ######################################################

      class << self
        
        # We delegate missing class (module) methods to the collins API client,
        # if it responds to them.
        def method_missing(name, *args, &block)
          if service.respond_to? name
            service.send name, *args, &block
          else
            super
          end
        end
        
        # Eigenclass mix-in for collins_attr_accessor
        # Calling "collins_attr_accessor :foo" in your class body will create
        # methods collins_foo and collins_foo= which automatically get/set
        # Collins attribute foo
        def included(base)
          base.class_eval do 
            def self.collins_attr_accessor(*fields)
              fields.each do |field|
                define_method("collins_#{field}") do
                  (collins_get(field) || '').downcase
                end
                define_method("collins_#{field}=") do |value|
                  collins_set(field, value)
                end
              end
            end
            
            # We make these 4 accessors available to ANY class including this mixin
            collins_attr_accessor :primary_role, :secondary_role, :pool, :status, :state
          end
        end
        
        # Returns the 'datacenter' config option for this plugin, or 'UNKNOWN-DC' if
        # none has been configured. This only matters in multi-datacenter Collins
        # topologies.
        def datacenter
          (Jetpants.plugins['jetpants_collins']['datacenter'] || 'UNKNOWN-DC').upcase
        end
        
        # Ordinarily, in a multi-dacenter environment, jetpants_collins places a number
        # of restrictions on interacting with assets that aren't in the local datacenter,
        # for safety's sake and to simplify how hierarchical replication trees are represented:
        #
        #   * Won't change Collins attributes on remote server node assets.
        #   * If a local node has a master in a remote datacenter, it is ignored/hidden.
        #   * If a local node has a slave in a remote datacenter, it's treated as a backup_slave,
        #     in order to prevent cross-datacenter master promotions. If any of these
        #     remote-datacenter slaves have slaves of their own, they're ignored/hidden.
        #   
        # You may DISABLE these restrictions by calling enable_inter_dc_mode. Normally you
        # do NOT want to do this, except in special sitautions like a migration between
        # datacenters.
        def enable_inter_dc_mode
          Jetpants.plugins['jetpants_collins']['inter_dc_mode'] = true
          Jetpants.plugins['jetpants_collins']['remote_lookup'] = true
        end
        
        # Returns true if enable_inter_dc_mode has been called, false otherwise.
        def inter_dc_mode?
          Jetpants.plugins['jetpants_collins']['inter_dc_mode'] || false
        end
        
        
        private
        
        # Returns a Collins::Client object
        def service
          return @collins_service if @collins_service
          
          %w(url user password).each do |setting|
            raise "No Collins #{setting} set in plugins -> jetpants_collins -> #{setting}" unless Jetpants.plugins['jetpants_collins'][setting]
          end
          
          logger = Logger.new(STDOUT)
          logger.level = Logger::INFO
          config = {
            :host     =>  Jetpants.plugins['jetpants_collins']['url'],
            :timeout  =>  Jetpants.plugins['jetpants_collins']['timeout'] || 30,
            :username =>  Jetpants.plugins['jetpants_collins']['user'],
            :password =>  Jetpants.plugins['jetpants_collins']['password'],
            :logger   =>  logger,
          }
          @collins_service = Collins::Client.new(config)
        end
      end
      
      
      ##### INSTANCE (MIX-IN) METHODS ##########################################
      
      # The base class needs to implement this!
      def collins_asset
        raise "Any class including Plugin::JetCollins must also implement collins_asset instance method!"
      end
      
      # Pass in a symbol, or array of symbols, to obtain from Collins for this
      # asset. For example, :status, :pool, :primary_role, :secondary_role.
      # If you pass in a single symbol, returns a single value.
      # If you pass in an array, returns a hash mapping each of these fields to their values.
      # Hash will also contain an extra field called :asset, storing the Collins::Asset object.
      def collins_get(*field_names)
        asset = collins_asset
        if field_names.count > 1 || field_names[0].is_a?(Array)
          field_names.flatten!
          want_state = !! field_names.delete(:state)
          results = Hash[field_names.map {|field| [field, (asset ? asset.send(field) : '')]}]
          results[:state] = asset.state.name if want_state
          results[:asset] = asset
          results
        elsif field_names.count == 1
          return '' unless asset
          if field_names[0] == :state
            asset.state.name
          else
            asset.send field_names[0]
          end
        else
          nil
        end
      end

      # Pass in a hash mapping field name symbols to values to set
      #   Symbol   => String         -- optionally set any Collins attribute
      #   :status  => String         -- optionally set the status value for the asset
      #   :asset   => Collins::Asset -- optionally pass this in to avoid an extra Collins API lookup, if asset already obtained
      #
      # Alternatively, pass in 2 strings (field_name, value) to set just a single Collins attribute (or status)
      def collins_set(*args)
        attrs = (args.count == 1 ? args[0] : {args[0] => args[1]})
        asset = attrs[:asset] || collins_asset
        
        # refuse to set Collins values on machines in remote data center unless
        # inter_dc_mode is enabled
        if asset && asset.type.downcase == 'server_node' && asset.location && asset.location.upcase != Plugin::JetCollins.datacenter
          asset = nil unless Jetpants::Plugin::JetCollins.inter_dc_mode?
        end
        
        attrs.each do |key, val|
          val ||= ''
          case key
          when :asset
            next
          when :status
            unless asset
              output "WARNING: unable to set Collins status to #{val}"
              next
            end
            if attrs[:state]
              previous_state = asset.state.name
              previous_status = asset.status
              if previous_state != attrs[:state].to_s || previous_status != attrs[:status].to_s
                success = Jetpants::Plugin::JetCollins.set_status!(asset, attrs[:status], 'changed through jetpants', attrs[:state])
                unless success
                  Jetpants::Plugin::JetCollins.state_create!(attrs[:state], attrs[:state], attrs[:state], attrs[:status])
                  success = Jetpants::Plugin::JetCollins.set_status!(asset, attrs[:status], 'changed through jetpants', attrs[:state])
                end
                raise "#{self}: Unable to set Collins state to #{attrs[:state]} and Unable to set Collins status to #{attrs[:status]}" unless success
                output "Collins state changed from #{previous_state} to #{attrs[:state]}"
                output "Collins status changed from #{previous_status} to #{attrs[:status]}"
              end              
            else
              previous_value = asset.status
              if previous_value != val.to_s
                success = Jetpants::Plugin::JetCollins.set_status!(asset, val)
                raise "#{self}: Unable to set Collins status to #{val}" unless success
                output "Collins status changed from #{previous_value} to #{val}"
              end
            end
          when :state
            unless asset && asset.status && attrs[:status]
              raise "#{self}: Unable to set state without settings a status" unless attrs[:status]
              output "WARNING: unable to set Collins state to #{val}"
              next
            end
          else
            unless asset
              output "WARNING: unable to set Collins attribute #{key} to #{val}"
              next
            end
            previous_value = asset.send(key)
            if previous_value != val.to_s.upcase
              success = Jetpants::Plugin::JetCollins.set_attribute!(asset, key.to_s.upcase, val.to_s.upcase)
              raise "#{self}: Unable to set Collins attribute #{key} to #{val}" unless success
              if (val.to_s == '' || !val) && (previous_value == '' || !previous_value)
                false
              elsif val.to_s == ''
                output "Collins attribute #{key.to_s.upcase} removed (was: #{previous_value})"
              elsif !previous_value || previous_value == ''
                output "Collins attribute #{key.to_s.upcase} set to #{val.to_s.upcase}"
              else
                output "Collins attribute #{key.to_s.upcase} changed from #{previous_value} to #{val.to_s.upcase}"
              end
            end
          end
        end
        
      end
      
    end # module JetCollins
  end # module Plugin
end


# load all the monkeypatches for other Jetpants classes
%w(asset host db pool shard topology).each {|mod| require "jetpants_collins/#{mod}"}

