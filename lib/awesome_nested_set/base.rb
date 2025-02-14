# encoding: utf-8
module CollectiveIdea #:nodoc:
  module Acts #:nodoc:
    module NestedSet #:nodoc:
      module Base
        def self.included(base)
          base.extend(SingletonMethods)
        end

        # This acts provides Nested Set functionality. Nested Set is a smart way to implement
        # an _ordered_ tree, with the added feature that you can select the children and all of their
        # descendants with a single query. The drawback is that insertion or move need some complex
        # sql queries. But everything is done here by this module!
        #
        # Nested sets are appropriate each time you want either an orderd tree (menus,
        # commercial categories) or an efficient way of querying big trees (threaded posts).
        #
        # == API
        #
        # Methods names are aligned with acts_as_tree as much as possible to make replacment from one
        # by another easier.
        #
        #   item.children.create(:name => "child1")
        #
        module SingletonMethods
          # Configuration options are:
          #
          # * +:parent_column+ - specifies the column name to use for keeping the position integer (default: parent_id)
          # * +:left_column+ - column name for left boundry data, default "lft"
          # * +:right_column+ - column name for right boundry data, default "rgt"
          # * +:scope+ - restricts what is to be considered a list. Given a symbol, it'll attach "_id"
          #   (if it hasn't been already) and use that as the foreign key restriction. You
          #   can also pass an array to scope by multiple attributes.
          #   Example: <tt>acts_as_nested_set :scope => [:notable_id, :notable_type]</tt>
          # * +:dependent+ - behavior for cascading destroy. If set to :destroy, all the
          #   child objects are destroyed alongside this object by calling their destroy
          #   method. If set to :delete_all (default), all the child objects are deleted
          #   without calling their destroy method.
          #
          # See CollectiveIdea::Acts::NestedSet::ClassMethods for a list of class methods and
          # CollectiveIdea::Acts::NestedSet::InstanceMethods for a list of instance methods added
          # to acts_as_nested_set models
          def acts_as_nested_set(options = {})
            options = {
              :parent_column => 'parent_id',
              :left_column => 'lft',
              :right_column => 'rgt',
              :dependent => :delete_all, # or :destroy
            }.merge(options)

            if options[:scope].is_a?(Symbol) && options[:scope].to_s !~ /_id$/
              options[:scope] = "#{options[:scope]}_id".intern
            end

            write_inheritable_attribute :acts_as_nested_set_options, options
            class_inheritable_reader :acts_as_nested_set_options

            unless self.is_a?(ClassMethods)
              include Comparable
              include Columns
              include InstanceMethods

              include Depth
              include Descendants

              extend Columns
              extend ClassMethods

              belongs_to :parent, :class_name => self.base_class.to_s,
                :foreign_key => parent_column_name
              has_many :children, :class_name => self.base_class.to_s,
                :foreign_key => parent_column_name, :order => quoted_left_column_name

              attr_accessor :skip_before_destroy

              # no bulk assignment
              if accessible_attributes.blank?
                attr_protected  left_column_name.intern, right_column_name.intern
              end

              before_create  :set_default_left_and_right
              before_save    :store_new_parent
              after_save     :move_to_new_parent
              before_destroy :destroy_descendants

              # no assignment to structure fields
              [left_column_name, right_column_name].each do |column|
                module_eval <<-"end_eval", __FILE__, __LINE__
                  def #{column}=(x)
                    raise ActiveRecord::ActiveRecordError, "Unauthorized assignment to #{column}: it's an internal field handled by acts_as_nested_set code, use move_to_* methods instead."
                  end
                end_eval
              end

              scope :roots, lambda {
                where(parent_column_name => nil).order(quoted_left_column_name)
              }
              scope :leaves, lambda {
                where("#{quoted_right_column_name} - #{quoted_left_column_name} = 1").
                order(quoted_left_column_name) 
              }
              scope :with_depth, proc {|level| where(:depth => level).order("lft") }

              define_callbacks :move, :terminator => "result == false"
            end
          end
        end

        module ClassMethods

          # Returns the first root
          def root
            roots.first
          end

          def valid?
            left_and_rights_valid? && no_duplicates_for_columns? && all_roots_valid?
          end

          def left_and_rights_valid?
            count(
              :joins => "LEFT OUTER JOIN #{quoted_table_name} AS parent ON " +
                "#{quoted_table_name}.#{quoted_parent_column_name} = parent.#{primary_key}",
              :conditions =>
                "#{quoted_table_name}.#{quoted_left_column_name} IS NULL OR " +
                "#{quoted_table_name}.#{quoted_right_column_name} IS NULL OR " +
                "#{quoted_table_name}.#{quoted_left_column_name} >= " +
                  "#{quoted_table_name}.#{quoted_right_column_name} OR " +
                "(#{quoted_table_name}.#{quoted_parent_column_name} IS NOT NULL AND " +
                  "(#{quoted_table_name}.#{quoted_left_column_name} <= parent.#{quoted_left_column_name} OR " +
                  "#{quoted_table_name}.#{quoted_right_column_name} >= parent.#{quoted_right_column_name}))"
            ) == 0
          end

          def no_duplicates_for_columns?
            scope_string = Array(acts_as_nested_set_options[:scope]).map do |c|
              connection.quote_column_name(c)
            end.push(nil).join(", ")
            [quoted_left_column_name, quoted_right_column_name].all? do |column|
              # No duplicates
              first(
                :select => "#{scope_string}#{column}, COUNT(#{column})",
                :group => "#{scope_string}#{column}
                  HAVING COUNT(#{column}) > 1").nil?
            end
          end

          # Wrapper for each_root_valid? that can deal with scope.
          def all_roots_valid?
            if acts_as_nested_set_options[:scope]
              roots(:group => scope_column_names).group_by{|record| scope_column_names.collect{|col| record.send(col.to_sym)}}.all? do |scope, grouped_roots|
                each_root_valid?(grouped_roots)
              end
            else
              each_root_valid?(roots)
            end
          end

          def each_root_valid?(roots_to_validate)
            left = right = 0
            roots_to_validate.all? do |root|
              (root.left > left && root.right > right).tap do
                left = root.left
                right = root.right
              end
            end
          end

          # Rebuilds the left & rights if unset or invalid.  Also very useful for converting from acts_as_tree.
          def rebuild!
            # Don't rebuild a valid tree.
            return true if valid?

            scope = lambda{|node|}
            if acts_as_nested_set_options[:scope]
              scope = lambda{|node|
                scope_column_names.inject(""){|str, column_name|
                  str << "AND #{connection.quote_column_name(column_name)} = #{connection.quote(node.send(column_name.to_sym))} "
                }
              }
            end
            indices = {}

            set_left_and_rights = lambda do |node|
              # set left
              node[left_column_name] = indices[scope.call(node)] += 1
              # find
              where("#{quoted_parent_column_name} = ? #{scope.call(node)}", node).
                order("#{quoted_left_column_name}, #{quoted_right_column_name}, id").
                all.each{|n| set_left_and_rights.call(n) }
              # set right
              node[right_column_name] = indices[scope.call(node)] += 1
              node.save!
            end

            # Find root node(s)
            root_nodes = where(parent_column_name => nil).
                order("#{quoted_left_column_name}, #{quoted_right_column_name}, id").
                all.each do |root_node|
              # setup index for this scope
              indices[scope.call(root_node)] ||= 0
              set_left_and_rights.call(root_node)
            end
          end

          # Iterates over tree elements and determines the current level in the tree.
          # Only accepts default ordering, odering by an other column than lft
          # does not work. This method is much more efficent than calling level
          # because it doesn't require any additional database queries.
          #
          # Example:
          #    Category.each_with_level(Category.root.self_and_descendants) do |o, level|
          #
          def each_with_level(objects)
            path = [nil]
            objects.each do |o|
              if o.parent_id != path.last
                # we are on a new level, did we decent or ascent?
                if path.include?(o.parent_id)
                  # remove wrong wrong tailing paths elements
                  path.pop while path.last != o.parent_id
                else
                  path << o.parent_id
                end
              end
              yield(o, path.length - 1)
            end
          end

          def before_move(*args, &block)
            set_callback :move, :before, *args, &block
          end

          def after_move(*args, &block)
            set_callback :move, :after, *args, &block
          end
        end

        # Mixed into both classes and instances to provide easy access to the column names
        module Columns
          def left_column_name
            acts_as_nested_set_options[:left_column]
          end

          def right_column_name
            acts_as_nested_set_options[:right_column]
          end

          def parent_column_name
            acts_as_nested_set_options[:parent_column]
          end

          def scope_column_names
            Array(acts_as_nested_set_options[:scope])
          end

          def quoted_left_column_name
            if ( self.is_a?(Class) && self.base_class.connected? ) || ( self.kind_of?(ActiveRecord::Base) && self.class.connected? )
              connection.quote_column_name(left_column_name)
            else
              left_column_name
            end
         end

          def quoted_right_column_name
            connection.quote_column_name(right_column_name)
          end

          def quoted_parent_column_name
            connection.quote_column_name(parent_column_name)
          end

          def quoted_scope_column_names
            scope_column_names.collect {|column_name| connection.quote_column_name(column_name) }
          end
        end

        # Any instance method that returns a collection makes use of Rails 2.1's named_scope (which is bundled for Rails 2.0), so it can be treated as a finder.
        #
        #   category.self_and_descendants.count
        #   category.ancestors.find(:all, :conditions => "name like '%foo%'")
        module InstanceMethods
          # Value of the parent column
          def parent_id
            self[parent_column_name]
          end

          # Value of the left column
          def left
            self[left_column_name]
          end

          # Value of the right column
          def right
            self[right_column_name]
          end

          # Returns true if this is a root node.
          def root?
            parent_id.nil?
          end

          def leaf?
            !new_record? && right - left == 1
          end

          # Returns true is this is a child node
          def child?
            !parent_id.nil?
          end

          # order by left column
          def <=>(x)
            left <=> x.left
          end

          # Redefine to act like active record
          def ==(comparison_object)
            comparison_object.equal?(self) ||
              (comparison_object.instance_of?(self.class) &&
                comparison_object.id == id &&
                !comparison_object.new_record?)
          end

          # Returns root
          def root
            self_and_ancestors.first
          end

          # Returns the array of all parents and self
          def self_and_ancestors
            nested_set_scope.scoped.where(
              "#{self.class.quoted_table_name}.#{quoted_left_column_name} <= ? AND #{self.class.quoted_table_name}.#{quoted_right_column_name} >= ?", left, right
            )
          end

          # Returns an array of all parents
          def ancestors
            without_self self_and_ancestors
          end

          # Returns the array of all children of the parent, including self
          def self_and_siblings
            nested_set_scope.scoped.where(parent_column_name => parent_id)
          end

          # Returns the array of all children of the parent, except self
          def siblings
            without_self self_and_siblings
          end

          # Returns a set of all of its nested children which do not have children
          def leaves
            descendants.scoped.where("#{self.class.quoted_table_name}.#{quoted_right_column_name} - #{self.class.quoted_table_name}.#{quoted_left_column_name} = 1")
          end

          # Returns the level of this object in the tree
          # root level is 0
          def level
            parent_id.nil? ? 0 : ancestors.count
          end

          # Returns a set of itself and all of its nested children
          def self_and_descendants
            nested_set_scope.scoped.where(
              "#{self.class.quoted_table_name}.#{quoted_left_column_name} >= ? AND #{self.class.quoted_table_name}.#{quoted_right_column_name} <= ?", left, right
            )
          end

          # Returns a set of all of its children and nested children
          def descendants
            without_self self_and_descendants
          end

          def is_descendant_of?(other)
            other.left < self.left && self.left < other.right && same_scope?(other)
          end

          def is_or_is_descendant_of?(other)
            other.left <= self.left && self.left < other.right && same_scope?(other)
          end

          def is_ancestor_of?(other)
            self.left < other.left && other.left < self.right && same_scope?(other)
          end

          def is_or_is_ancestor_of?(other)
            self.left <= other.left && other.left < self.right && same_scope?(other)
          end

          # Check if other model is in the same scope
          def same_scope?(other)
            Array(acts_as_nested_set_options[:scope]).all? do |attr|
              self.send(attr) == other.send(attr)
            end
          end

          # Find the first sibling to the left
          def left_sibling
            siblings.first(:conditions => ["#{self.class.quoted_table_name}.#{quoted_left_column_name} < ?", left],
              :order => "#{self.class.quoted_table_name}.#{quoted_left_column_name} DESC")
          end

          # Find the first sibling to the right
          def right_sibling
            siblings.first(:conditions => ["#{self.class.quoted_table_name}.#{quoted_left_column_name} > ?", left])
          end

          # Shorthand method for finding the left sibling and moving to the left of it.
          def move_left
            move_to_left_of left_sibling
          end

          # Shorthand method for finding the right sibling and moving to the right of it.
          def move_right
            move_to_right_of right_sibling
          end

          # Move the node to the left of another node (you can pass id only)
          def move_to_left_of(node)
            move_to node, :left
          end

          # Move the node to the left of another node (you can pass id only)
          def move_to_right_of(node)
            move_to node, :right
          end

          # Move the node to the child of another node (you can pass id only)
          def move_to_child_of(node)
            move_to node, :child
          end

          # Move the node to root nodes
          def move_to_root
            move_to nil, :root
          end

          def move_possible?(target)
            self != target && # Can't target self
            same_scope?(target) && # can't be in different scopes
            # !(left..right).include?(target.left..target.right) # this needs tested more
            # detect impossible move
            !((left <= target.left && right >= target.left) or (left <= target.right && right >= target.right))
          end

          def to_text
            self_and_descendants.map do |node|
              "#{'*'*(node.level+1)} #{node.id} #{node.to_s} (#{node.parent_id}, #{node.left}, #{node.right})"
            end.join("\n")
          end

        protected

          def without_self(scope)
            scope.where("#{self.class.quoted_table_name}.#{self.class.primary_key} != ?", self)
          end

          # All nested set queries should use this nested_set_scope, which performs finds on
          # the base ActiveRecord class, using the :scope declared in the acts_as_nested_set
          # declaration.
          def nested_set_scope
            options = {:order => quoted_left_column_name}
            scopes = Array(acts_as_nested_set_options[:scope])
            options[:conditions] = scopes.inject({}) do |conditions,attr|
              conditions.merge attr => self[attr]
            end unless scopes.empty?
            self.class.base_class.scoped options
          end

          def store_new_parent
            @move_to_new_parent_id = send("#{parent_column_name}_changed?") ? parent_id : false
            true # force callback to return true
          end

          def move_to_new_parent
            if @move_to_new_parent_id.nil?
              move_to_root
            elsif @move_to_new_parent_id
              move_to_child_of(@move_to_new_parent_id)
            end
          end

          # on creation, set automatically lft and rgt to the end of the tree
          def set_default_left_and_right
            maxright = nested_set_scope.maximum(right_column_name) || 0
            # adds the new node to the right of all existing nodes
            self[left_column_name] = maxright + 1
            self[right_column_name] = maxright + 2
          end

          # Prunes a branch off of the tree, shifting all of the elements on the right
          # back to the left so the counts still work.
          def destroy_descendants
            return if right.nil? || left.nil? || skip_before_destroy

            self.class.base_class.transaction do
              if acts_as_nested_set_options[:dependent] == :destroy
                descendants.each do |model|
                  model.skip_before_destroy = true
                  model.destroy
                end
              else
                nested_set_scope.delete_all(
                  ["#{quoted_left_column_name} > ? AND #{quoted_right_column_name} < ?",
                    left, right]
                )
              end

              # update lefts and rights for remaining nodes
              diff = right - left + 1
              nested_set_scope.update_all(
                ["#{quoted_left_column_name} = (#{quoted_left_column_name} - ?)", diff],
                ["#{quoted_left_column_name} > ?", right]
              )
              nested_set_scope.update_all(
                ["#{quoted_right_column_name} = (#{quoted_right_column_name} - ?)", diff],
                ["#{quoted_right_column_name} > ?", right]
              )

              # Don't allow multiple calls to destroy to corrupt the set
              self.skip_before_destroy = true
            end
          end

          # reload left, right, and parent
          def reload_nested_set
            reload(:select => "#{quoted_left_column_name}, " +
              "#{quoted_right_column_name}, #{quoted_parent_column_name}")
          end

          def move_to(target, position)
            raise ActiveRecord::ActiveRecordError, "You cannot move a new node" if self.new_record?

            res = run_callbacks :move do
              transaction do
                if target.is_a? self.class.base_class
                  target.reload_nested_set
                elsif position != :root
                  # load object if node is not an object
                  target = nested_set_scope.find(target)
                end
                self.reload_nested_set

                unless position == :root || move_possible?(target)
                  raise ActiveRecord::ActiveRecordError, "Impossible move, target node cannot be inside moved tree."
                end

                bound = case position
                  when :child;  target[right_column_name]
                  when :left;   target[left_column_name]
                  when :right;  target[right_column_name] + 1
                  when :root;   1
                  else raise ActiveRecord::ActiveRecordError, "Position should be :child, :left, :right or :root ('#{position}' received)."
                end

                if bound > self[right_column_name]
                  bound = bound - 1
                  other_bound = self[right_column_name] + 1
                else
                  other_bound = self[left_column_name] - 1
                end

                # there would be no change
                return if bound == self[right_column_name] || bound == self[left_column_name]

                # we have defined the boundaries of two non-overlapping intervals,
                # so sorting puts both the intervals and their boundaries in order
                a, b, c, d = [self[left_column_name], self[right_column_name], bound, other_bound].sort

                new_parent = case position
                  when :child;  target.id
                  when :root;   nil
                  else          target[parent_column_name]
                end

                nested_set_scope.update_all([
                  "#{quoted_left_column_name} = CASE " +
                    "WHEN #{quoted_left_column_name} BETWEEN :a AND :b " +
                      "THEN #{quoted_left_column_name} + :d - :b " +
                    "WHEN #{quoted_left_column_name} BETWEEN :c AND :d " +
                      "THEN #{quoted_left_column_name} + :a - :c " +
                    "ELSE #{quoted_left_column_name} END, " +
                  "#{quoted_right_column_name} = CASE " +
                    "WHEN #{quoted_right_column_name} BETWEEN :a AND :b " +
                      "THEN #{quoted_right_column_name} + :d - :b " +
                    "WHEN #{quoted_right_column_name} BETWEEN :c AND :d " +
                      "THEN #{quoted_right_column_name} + :a - :c " +
                    "ELSE #{quoted_right_column_name} END, " +
                  "#{quoted_parent_column_name} = CASE " +
                    "WHEN #{self.class.base_class.primary_key} = :id THEN :new_parent " +
                    "ELSE #{quoted_parent_column_name} END",
                  {:a => a, :b => b, :c => c, :d => d, :id => self.id, :new_parent => new_parent}
                ])
              end
              target.reload_nested_set if target
              self.reload_nested_set
              self.update_depth if depth?
            end
          end
        end
      end # Base
    end # NestedSet
  end # Acts
end # CollectiveIdea
