#     Copyright 2016 Netflix, Inc.
#
#     Licensed under the Apache License, Version 2.0 (the "License");
#     you may not use this file except in compliance with the License.
#     You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#     Unless required by applicable law or agreed to in writing, software
#     distributed under the License is distributed on an "AS IS" BASIS,
#     WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#     See the License for the specific language governing permissions and
#     limitations under the License.


# ScumblrTask class for automatic multithreading
# To use: Inherit this class, define a "perform_work" function that
# accepts one argument (the object to operate on) and define @results
# which is a list of objects to perform_work on. Optionally define
# @workers to be the number of worker threads
class ScumblrTask::Async < ScumblrTask::Base


  def run
    if(!self.respond_to?(:perform_work))
      msg = "Incorrectly implemented Async Task. No \"perform_work\" method defined. #{self.inspect}"
      Rails.logger.error msg
      create_error(msg)
      return
    end

    # Semaphore to be used for synchronizing threads
    @semaphore = Mutex.new

    # Default number of workers
    @workers ||= 10

    # Database connection retry behavior
    @database_max_retries ||= 10
    @database_backoff_time ||= 30

    # Default to empty array of results to iterate
    @results ||= []

    # Final results will be returned at the end of the task
    @final_results = []

    threads = []

    queue = Queue.new

    #total_count is only available for Kaminari paged objects
    if @results.respond_to?(:total_count)
      total = @results.total_count
    else
      total = @results.count
    end
    
    threads << Thread.new do
      other_workers_running = false
      i = 1
      @results.find_each(batch_size: 200) do |r|
        #we only want to check if the other threads have had a chance to start up
        threads_alive = 0
        if threads.size > 2
          threads.each_with_index do |check_thread, index|
            if check_thread.alive? && index != 0
              other_workers_running = true
              threads_alive += 1
            end
          end
        end

        #if it's less than 2 (this and one other) time to end this thread or we'll loop forever
        #this is for cases when all the workers died for some reason (error)
        if other_workers_running && threads_alive == 0
          Rails.logger.info "breaking out of queue thread"
          break
        end
        #we'll put 100 per worker in the queue
        while queue.size > @workers * 20
          sleep 0.5
          Rails.logger.info "in queue thread sleep"
        end
        Rails.logger.info "pushing onto queue: #{r.title.inspect}"
        #we have less than 1000, let's add one to the queue
        queue.push([i, r])
        i += 1
      end
      Rails.logger.info "queue thread finished all results"
    end
    @parent_tracker ||= {}
    @parent_tracker["current_events"] ||= {}
    @parent_tracker["current_events"]["Error"] ||= []
    @parent_tracker["current_events"]["Warning"] ||= []

    @parent_tracker["current_results"] ||= {}
    @parent_tracker["current_results"]["created"] ||= []
    @parent_tracker["current_results"]["updated"] ||= []

    #lets get some stuff in the queue (or not if there are no results to add to the queue)
    while(threads[0].alive? && queue.empty?)
      sleep 0.01
      Rails.logger.info "waiting for queue to have something in it, or if first thread died"
    end

    @workers.times do |i|
      threads << Thread.new do
        thread_tracker = ThreadTracker.new()
        thread_tracker.create_tracking_thread(@options[:_self])
        retries = 0
        begin
          ActiveRecord::Base.connection_pool.with_connection do
            #run while the queue loading thread is still loading items
            #or if that finished loading, until the queue is empty
            while(threads[0].alive? || !queue.empty?)
              if(r_i = queue.pop(true))
                beginning_time = Time.now
                r = r_i[1]
                i = r_i[0]
                Rails.logger.debug "#{self.class.task_type_name}: Processing #{i} of #{total}"
                begin
                  perform_work(r)
                    @semaphore.synchronize {
                      if Thread.current[:current_task]
                        unless Thread.current["current_events"].nil?
                          @parent_tracker["current_events"]["Error"].push(*Thread.current["current_events"].try(:[], "Error"))
                          @parent_tracker["current_events"]["Error"].uniq!
                          @parent_tracker["current_events"]["Warning"].push(*Thread.current["current_events"].try(:[], "Warning"))
                          @parent_tracker["current_events"]["Warning"].uniq!
                        end
                        unless Thread.current["current_results"].nil?
                          @parent_tracker["current_results"]["created"].push(*Thread.current["current_results"].try(:[], "created"))
                          @parent_tracker["current_results"]["created"].uniq!
                          @parent_tracker["current_results"]["updated"].push(*Thread.current["current_results"].try(:[], "updated"))
                          @parent_tracker["current_results"]["updated"].uniq!
                        end
                      end
                    }
                  end_time = Time.now
                  #pid, size = `ps ax -o pid,rss | grep -E "^[[:space:]]*#{$$}"`.strip.split.map(&:to_i)
                  Rails.logger.info "Record # #{i} - time: #{(end_time - beginning_time)*1000} milliseconds"
                  r_i = nil
                rescue => e
                  create_error(e)
                end
              else
                #wait for a bit to let the other thread fill the queue
                while(threads[0].alive? && queue.empty?)
                  sleep 0.01
                  Rails.logger.info "in sleep waiting of queue to be filled"
                end
              end
            end
          end
        rescue ActiveRecord::ConnectionTimeoutError=>e

          retries += 1
          if retries > @database_max_retries
            #Create an error indicating a thread could not acquire a database connection
            create_error(e)

          end
          sleep(@database_backoff_time)
          retry

        rescue ThreadError => e
          Rails.logger.info e.inspect
        rescue=>e
          create_error(e)
        ensure
          #ActiveRecord::Base.clear_active_connections!
          #ActiveRecord::Base.connection.close
        end

      end
      # Final End

    end


    threads.map(&:join);
    if Thread.current[:current_task]
      Thread.current["current_results"] = @parent_tracker["current_results"]
      Thread.current["current_events"] = @parent_tracker["current_events"]
    end
    return @final_results
  end

end
