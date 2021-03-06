module RailsAdmin

  # This module adds the default_scope class method to a model. It is included in the model adapters.
  module CurrentScope
    module ClassMethods
      # Returns a scope which fetches only the records that the passed ability
      # can perform a given action on. 
      # authorization_adapter and scope_adapter are instance variables set at the controller level.
      def limit_scope(authorization_adapter, scope_adapter)
        abstract_model = RailsAdmin::AbstractModel.new(self.name)
        if authorization_adapter
          scope = authorization_adapter.query(:read, abstract_model)
        else
          scope = abstract_model.model
        end

        scope = where("1 = 0") if scope == nil #prevent the query to work if someone something went wrong and the scope gets nil

        scope = scope_adapter.apply_scope(scope, abstract_model) if scope_adapter
      end
    end

    def self.included(base)
      base.extend ClassMethods
    end
  end
end

ActiveRecord::Base.class_eval do
  include RailsAdmin::CurrentScope
end

class ActiveRecord::Base
  module DeepCloneable
    @@rails31 = ActiveRecord::VERSION::MAJOR >= 3 && ActiveRecord::VERSION::MINOR > 0

    # ActiveRecord::Base has its own dup method for Ruby 1.8.7. We have to
    # redefine it and put it in a module so that we can override it in a
    # module and call the original with super().
    if @@rails31 and !Object.respond_to? :initialize_dup
      ActiveRecord::Base.class_eval do
        module Dup
          def dup
            copy = super
            copy.initialize_dup(self)
            copy
          end
        end
        remove_method :dup
        include Dup
      end
    end

    # clones an ActiveRecord model. 
    # if passed the :include option, it will deep clone the given associations
    # if passed the :except option, it won't clone the given attributes
    #
    # === Usage:
    # 
    # ==== Cloning one single association
    #    pirate.clone :include => :mateys
    # 
    # ==== Cloning multiple associations
    #    pirate.clone :include => [:mateys, :treasures]
    # 
    # ==== Cloning really deep
    #    pirate.clone :include => {:treasures => :gold_pieces}
    # 
    # ==== Cloning really deep with multiple associations
    #    pirate.clone :include => [:mateys, {:treasures => :gold_pieces}]
    #
    # ==== Cloning really deep with multiple associations and a dictionary
    #
    # A dictionary ensures that models are not cloned multiple times when it is associated to nested models. 
    # When using a dictionary, ensure recurring associations are cloned first:
    #
    #    pirate.clone :include => [:mateys, {:treasures => [:matey, :gold_pieces], :use_dictionary => true }]    
    #
    # If this is not an option for you, it is also possible to populate the dictionary manually in advance:
    #
    #    dict = { :mateys => {} }
    #    pirate.mateys.each{|m| dict[:mateys][m] = m.clone }
    #    pirate.clone :include => [:mateys, {:treasures => [:matey, :gold_pieces], :dictionary => dict }]    
    #   
    # ==== Cloning a model without an attribute
    #    pirate.clone :except => :name
    #  
    # ==== Cloning a model without multiple attributes
    #    pirate.clone :except => [:name, :nick_name]
    #    
    # ==== Cloning a model without an attribute or nested multiple attributes   
    #    pirate.clone :include => :parrot, :except => [:name, { :parrot => [:name] }]
    # 
    define_method (@@rails31 ? :dup : :clone) do |*args|
      options = args[0] || {}
      
      dict = options[:dictionary]
      dict ||= {} if options.delete(:use_dictionary)
      
      kopy = unless dict
        super()
      else
        tableized_class = self.class.name.tableize.to_sym
        dict[tableized_class] ||= {}
        dict[tableized_class][self] ||= super()
      end

      deep_exceptions = {}
      if options[:except]
        exceptions = options[:except].nil? ? [] : [options[:except]].flatten
        exceptions.each do |attribute|
          kopy.send(:write_attribute, attribute, attributes_from_column_definition[attribute.to_s]) unless attribute.kind_of?(Hash)
        end
        deep_exceptions = exceptions.select{|e| e.kind_of?(Hash) }.inject({}){|m,h| m.merge(h) }
      end
    
      if options[:include]
        Array(options[:include]).each do |association, deep_associations|
          if (association.kind_of? Hash)
            deep_associations = association[association.keys.first]
            association = association.keys.first
          end
          
          opts = deep_associations.blank? ? {} : {:include => deep_associations}
          opts.merge!(:except => deep_exceptions[association]) if deep_exceptions[association]
          opts.merge!(:dictionary => dict) if dict
        
          association_reflection = self.class.reflect_on_association(association)
          raise AssociationNotFoundException.new("#{self.class}##{association}") if association_reflection.nil?
                    
          cloned_object = case association_reflection.macro
            when :belongs_to, :has_one
              self.send(association) && self.send(association).send(__method__, opts)
            when :has_many, :has_and_belongs_to_many
              primary_key_name = (@@rails31 ? association_reflection.foreign_key : association_reflection.primary_key_name).to_s
              
              reverse_association_name = association_reflection.klass.reflect_on_all_associations.detect do |a|
                  a.send(@@rails31 ? :foreign_key : :primary_key_name).to_s == primary_key_name
              end.try(:name)
              
              self.send(association).collect do |obj| 
                tmp = obj.send(__method__, opts)
                tmp.send("#{primary_key_name}=", nil)                
                tmp.send("#{reverse_association_name.to_s}=", kopy) if reverse_association_name
                tmp
              end
            end
          kopy.send("#{association}=", cloned_object)
        end
      end

      return kopy
    end
    
    class AssociationNotFoundException < StandardError; end    
  end
  
  include DeepCloneable
end
