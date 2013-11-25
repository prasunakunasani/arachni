=begin
    Copyright 2010-2014 Tasos Laskos <tasos.laskos@gmail.com>
    All rights reserved.
=end

module Arachni

require 'nokogiri'
require Options.dir['lib'] + 'nokogiri/xml/node'

#
# Crawls the target webapp until there are no new paths left.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Spider
    include UI::Output
    include Utilities

    # How many times to retry failed requests.
    MAX_TRIES = 5

    # @return [Arachni::Options]
    attr_reader :opts

    # @return [Array<String>]   URLs that caused redirects
    attr_reader :redirects

    # @return [Array<String>]
    #   URLs that elicited no response from the server.
    #   Not determined by HTTP status codes, we're talking network failures here.
    attr_reader :failures

    #
    # Instantiates Spider class with user options.
    #
    # @param  [Arachni::Options] opts
    #
    def initialize( opts = Options.instance )
        @opts = opts

        @mutex     = Mutex.new
        @sitemap   = {}
        @redirects = []
        @paths     = Set.new
        @visited   = Support::LookUp::HashSet.new
        @mutex     = Mutex.new

        @on_each_page_blocks     = []
        @on_each_response_blocks = []
        @on_complete_blocks      = []

        @pass_pages       = true
        @pending_requests = 0

        @retries  = {}
        @failures = []

        seed_paths
    end

    def url
        @opts.url
    end

    # @return   [Set<String>]
    #   Working paths, paths that haven't yet been followed.
    #   If you want to add more paths use {#push}.
    def paths
        @paths
    end

    # @return   [Array<String>] list of crawled URLs
    def sitemap
        @sitemap.keys
    end

    # @return   [Hash<Integer, String>] list of crawled URLs with their HTTP codes
    def fancy_sitemap
        @sitemap
    end

    # Runs the Spider and passes the requested object to the block.
    #
    # @param [Block] block  To be passed each page as visited.
    #
    # @return [Array<String>]   sitemap
    def run( &block )
        return if running? || limit_reached? || !@opts.crawl?

        synchronize { @running = true }

        # Options could have changed so reseed.
        seed_paths

        on_each_page( &block ) if block_given?

        while !done?
            wait_if_paused
            while !done? && (url = next_url)
                wait_if_paused

                visit( url ) do |page|
                    call_on_each_page_blocks page
                    distribute page.paths
                end
            end

            http.run
        end

        synchronize { @running = false }

        call_on_complete_blocks

        sitemap
    end

    def running?
        synchronize { !!@running }
    end

    # @param    [Block] block
    #   Sets blocks to be called every time a page is visited.
    def on_each_page( &block )
        fail ArgumentError, 'Block is mandatory!' if !block_given?
        @on_each_page_blocks << block
        self
    end

    # @param    [Block]    block
    #   Sets blocks to be called once the crawler is done.
    def on_complete( &block )
        fail ArgumentError, 'Block is mandatory!' if !block_given?
        @on_complete_blocks << block
        self
    end

    #
    # Pushes new paths for the crawler to follow; if the crawler has finished
    # it will be awaken when new paths are pushed.
    #
    # The paths will be sanitized and normalized (cleaned up and converted to
    # absolute ones).
    #
    # @param    [String, Array<String>] paths
    #
    # @return   [Bool]
    #   `true` if push was successful, `false` otherwise (provided empty or
    #   paths that must be skipped).
    #
    def push( paths, wakeup = true )
        return false if limit_reached?

        paths = dedup( paths )
        return false if paths.empty?

        synchronize do
            @paths |= paths
        end

        return true if !wakeup || running?
        Thread.abort_on_exception = true
        Thread.new { run }

        true
    end

    # @return [TrueClass, FalseClass] `true` if crawl is done, `false` otherwise.
    def done?
        idle? || limit_reached?
    end

    # @return [TrueClass, FalseClass]
    #   `true` if the queue is empty and no requests are pending, `false` otherwise.
    def idle?
        synchronize do
            @paths.empty? && @pending_requests == 0
        end
    end

    # @return [TrueClass] Pauses the system on a best effort basis.
    def pause
        @pause = true
    end

    # @return [TrueClass] Resumes the system.
    def resume
        @pause = false
        true
    end

    # @return [Bool] `true` if the system it paused, `false` otherwise.
    def paused?
        @pause ||= false
    end

    private

    def dedup( paths )
        return [] if !paths || paths.empty?

        [paths].flatten.map do |path|
            next if !path
            path = to_absolute( path, url )
            next if !path || skip?( path )

            path
        end.compact
    end

    def next_url
        synchronize { @paths.shift }
    end

    def synchronize( &block )
        @mutex.synchronize( &block )
    end

    def distribute( urls )
        push( urls, false )
    end

    def seed_paths
        push( url, false )
        push( @opts.extend_paths, false )
    end

    def call_on_each_page_blocks( obj )
        @on_each_page_blocks.each { |b| exception_jail( false ) { b.call( obj ) } }
    end

    def call_on_complete_blocks
        @on_complete_blocks.each { |b| exception_jail( false ) { b.call } }
    end

    # @return   [Arachni::HTTP]   HTTP interface
    def http
        HTTP::Client
    end

    #
    # Decides if a URL should be skipped based on weather it:
    #
    # * has previously been {#visited?}
    # * matches a {#redundant?} filter
    # * matches universal {#skip_path?} options like inclusion and exclusion filters
    #
    # @param    [String]    url to check
    #
    # @return   [Bool]  true if any of the 3 filters returns true, false otherwise
    #
    def skip?( url )
        if visited?( url )
            print_debug "Skipping already visited URL: #{url}"
            return true
        end

        return false if self.url == url

        if skip_path?( url )
            print_verbose "Skipping out of scope URL: #{url}"
            return true
        end

        false
    end

    def skip_response?( response )
        response.url != self.url && super( response )
    end

    #
    # @param    [String]    url
    #
    # @return   [Bool]  true if the url has already been visited, false otherwise
    #
    def visited?( url )
        @visited.include?( url )
    end

    # @return   [Bool]  true if the link-count-limit has been exceeded, false otherwise
    def limit_reached?
        @opts.link_count_limit_reached? @visited.size
    end

    #
    # Checks if the provided URL matches a redundant filter
    # and decreases its counter if so.
    #
    # If a filter's counter has reached 0 the method returns true.
    #
    # @param    [String]    url
    #
    # @return   [Bool]  true if the url is redundant, false otherwise
    #
    def redundant?( url )
        redundant = redundant_path?( url ) do |count, regexp, path|
            print_info "Matched redundancy rule: #{regexp} for #{path}"
            print_info "Count-down: #{count}"
        end

        print_verbose "Discarding redundant page: #{url}" if redundant
        redundant
    end

    def auto_redundant?( url )
        @opts.auto_redundant_path?( url ) do
            print_verbose "Discarding auto-redundant page: #{url}"
        end
    end

    def wait_if_paused
        ::IO::select( nil, nil, nil, 1 ) while( paused? )
    end

    def hit_redirect_limit?
        @opts.redirect_limit > 0 && @opts.redirect_limit <= @followed_redirects
    end

    def visit( url, opts = {}, &block )
        return if skip?( url ) || redundant?( url ) || auto_redundant?( url )
        visited( url )

        @followed_redirects ||= 0
        @pending_requests += 1

        opts = {
            timeout:         nil,
            follow_location: false,
            update_cookies:  true
        }.merge( opts )

        wrap = proc do |response|
            effective_url = normalize_url( response.url )

            if response.code == 0
                @retries[url.hash] ||= 0

                if @retries[url.hash] >= MAX_TRIES
                    @failures << url

                    print_error "Giving up on: #{effective_url}"
                    print_error "Couldn't get a response after #{MAX_TRIES} tries."
                    print_error "Because: #{response.return_message}"
                else
                    @retries[url.hash] += 1
                    repush( url )

                    print_info "Retrying for: #{effective_url}"
                    print_bad "Because: #{response.return_message}"
                    print_line
                end

                decrease_pending
                next
            end

            print_status "[HTTP: #{response.code}] #{effective_url}"

            if response.redirection?
                @redirects << response.request.url
                location = to_absolute( response.headers.location, response.request.url )
                if hit_redirect_limit? || skip?( location )
                    print_info "Redirect limit reached, skipping: #{location}"
                    decrease_pending
                    next
                end
                @followed_redirects += 1

                print_info "Scheduled to follow: #{location}"
                push location
            end

            if skip_response?( response )
                print_info 'Ignoring due to exclusion criteria.'
            else
                @sitemap[effective_url] = response.code
                block.call response.to_page
            end

            decrease_pending
        end

        http.get( url, opts, &wrap )
    rescue
        decrease_pending
        nil
    end

    def decrease_pending
        @pending_requests -= 1
    end

    def visited( url )
        @visited << url
    end

    def repush( url )
        @visited.delete url
        push url
    end

    def intercept_print_message( msg )
        "Spider: #{msg}"
    end

end
end
