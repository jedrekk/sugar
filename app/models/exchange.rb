require 'pagination'

class Exchange < ActiveRecord::Base
	
	set_table_name 'discussions'

	UNSAFE_ATTRIBUTES    = :id, :sticky, :user_id, :last_poster_id, :posts_count, :created_at, :last_post_at, :trusted
	DISCUSSIONS_PER_PAGE = 30

	belongs_to :poster,      :class_name => 'User', :counter_cache => :discussions_count
	belongs_to :closer,      :class_name => 'User'
	belongs_to :last_poster, :class_name => 'User'
	has_many   :posts, :order => ['created_at ASC'], :dependent => :destroy, :foreign_key => 'discussion_id'
	has_one    :first_post, :class_name => 'Post',   :order => ['created_at ASC']
	has_many   :discussion_views,                    :dependent => :destroy

	validates_presence_of :title
	validates_length_of   :title, :maximum => 100, :too_long => 'is too long'

	# Virtual attribute for the body of the first post. 
	# Makes forms a bit easier, no nested models.
	attr_accessor         :body, :skip_validation
	validates_presence_of :body, :on => :create, :unless => :skip_validation
	
	# Flag for trusted status, which will update after save if it has been changed.
	attr_accessor :update_trusted, :new_closer

	validate do |discussion|
		if discussion.closed_changed?
			if !discussion.closed? && (!discussion.new_closer || !discussion.closeable_by?(discussion.new_closer))
				discussion.errors.add(:closed, "can't be changed!") 
			elsif discussion.closed?
				discussion.closer = discussion.new_closer
			else
				discussion.closer = nil
			end
		end
	end
	
	# Update the first post if @body has been changed
	after_update do |discussion|
		if discussion.body && !discussion.body.empty? && discussion.body != discussion.posts.first.body
			discussion.posts.first.update_attributes(:body => discussion.body, :edited_at => Time.now)
		end
	end

	before_update do |discussion|
		discussion.update_trusted = true if discussion.trusted_changed?
	end

	# Automatically create the first post
	after_create do |discussion|
		discussion.create_first_post!
	end

	define_index do
		indexes title
		has     type
		has     poster_id, last_poster_id, category_id
		has     trusted
		has     closed
		has     sticky
		has     created_at, updated_at, last_post_at, posts_count
		set_property :delta => :delayed
		set_property :field_weights => {:title => 2}
	end

	# Class methods
	class << self

		# Enable work safe URLs
		def work_safe_urls=(state)
			@@work_safe_urls = state
		end

		def work_safe_urls
			@@work_safe_urls ||= false
		end

		def search_paginated(options={})
			page  = (options[:page] || 1).to_i
			page = 1 if page < 1
			max_posts_count = Discussion.find(:first, :order => 'posts_count DESC').posts_count
			first_post_date = Post.find(:first, :order => 'created_at ASC').created_at
			search_options = {
				#:sort_mode  => :expr,
				#:sort_by    => "@weight + (posts_count / #{max_posts_count}) * (1 - ((now() - last_post_at) / (now() - #{first_post_date.to_i})))",
				:sort_mode  => :desc, 
				:order      => :last_post_at, 
				:per_page   => DISCUSSIONS_PER_PAGE,
				:page       => page,
				:include    => [:poster, :last_poster, :category],
				:match_mode => :extended2
			}
			search_options[:conditions] = {:trusted => false} unless options[:trusted]
			discussions = Discussion.search(options[:query], search_options)
			Pagination.apply(discussions, Pagination::Paginater.new(:total_count => discussions.total_entries, :page => page, :per_page => DISCUSSIONS_PER_PAGE))
		end
		
		# Finds paginated discussions, sorted by activity, with the sticky ones on top.
		# The collection is decorated with the Pagination module, which provides pagination info.
		# Takes the following options: 
		# * :page     - Page number, starting on 1 (default: first page)
		# * :limit    - Number of posts per page (default: 20)
		# * :category - Only get discussions in this category
		# * :trusted  - Boolean, get trusted posts as well
		def find_paginated(options={})
			conditions = options[:category] ? ['category_id = ?', options[:category].id] : []

			# Ignore trusted posts unless requested
			unless options[:trusted]
				conditions = [[conditions.shift, 'trusted = 0'].compact.join(' AND ')] + conditions
			end

			# Utilize the counter cache on category if possible, if not do the query.
			discussions_count   = options[:category].discussions_count if options[:category]
			discussions_count ||= Discussion.count(:conditions => conditions)

			Pagination.paginate(
				:total_count => discussions_count,
				:per_page    => options[:limit] || DISCUSSIONS_PER_PAGE,
				:page        => options[:page]  || 1
			) do |pagination|
				Discussion.find(
					:all, 
					:conditions => conditions, 
					:limit      => pagination.limit, 
					:offset     => pagination.offset, 
					:order      => 'sticky DESC, last_post_at DESC',
					:include    => [:poster, :last_poster, :category]
				)
			end
		end

		# Deletes attributes which normal users shouldn't be able to touch from a param hash
		def safe_attributes(params)
			safe_params = params.dup
			Exchange::UNSAFE_ATTRIBUTES.each do |r|
				safe_params.delete(r)
			end
			return safe_params
		end
		
		# Counts total discussion for a user
		def count_for(user)
			(user && user.trusted?) ? Discussion.count(:all) : Discussion.count(:all, :conditions => {:trusted => 0})
		end

	end
	
	# Finds paginated posts. See <tt>Post.find_paginated</tt> for more info.
	def paginated_posts(options={})
		Post.find_paginated({:discussion => self}.merge(options))
	end

	# Finds posts created since offset.
	def posts_since_index(offset)
		Post.find(:all, 
			:conditions => ['discussion_id = ?', self.id], 
			:order      => 'created_at ASC',
			:limit      => 200,
			:offset     => offset,
			:include    => [:user]
		)
	end

	# Finds the number of the last page.
	def last_page(per_page=Post::POSTS_PER_PAGE)
		(self.posts_count.to_f/per_page).ceil
	end
	
	# Creates the first post.
	def create_first_post!
		if self.body && !self.body.empty?
			self.posts.create(:user => self.poster, :body => self.body)
		end
	end

	def fix_counter_cache!
		if posts_count != posts.count
			logger.warn "counter_cache error detected on Discussion ##{self.id}"
			Exchange.update_counters(self.id, :posts_count => (posts.count - posts_count) )
		end
	end

	# Does this discussion have any labels?
	def labels?
		(self.closed? || self.sticky? || self.nsfw? || self.trusted?) ? true : false
	end

	# Returns an array of labels (for use in the thread title)
	def labels
		labels = []
		labels << "Trusted" if self.trusted?
		labels << "Sticky"  if self.sticky?
		labels << "Closed"  if self.closed?
		labels << "NSFW"    if self.nsfw?
		return labels
	end

	# Humanized ID for URLs
	def to_param
		slug = self.title
		slug = slug.gsub(/[\[\{]/,'(')
		slug = slug.gsub(/[\]\}]/,')')
		slug = slug.gsub(/[^\w\d!$&'()*,;=\-]+/,'-').gsub(/[\-]{2,}/,'-').gsub(/(^\-|\-$)/,'')
		(Discussion.work_safe_urls) ? self.id.to_s : "#{self.id.to_s};" + slug
	end
	
	if ENV['RAILS_ENV'] == 'test'
		def posts_count
			self.posts.count
		end 
	end
	
end
