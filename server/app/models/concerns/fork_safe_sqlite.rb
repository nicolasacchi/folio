# Pid-keyed memoization for a module-level SQLite3::Database handle, shared
# by BookSearch, Dictionary and Library::Embeddings — each keeps its data in
# its own SQLite file (outside the primary database) behind a single
# process-wide connection guarded by a mutex.
#
# sqlite3-ruby's fork-safety hook (SQLite3::ForkSafety) closes every
# *tracked* writable handle in the process that actually calls fork, then
# clears its registry — but Solid Queue's worker is a *double* fork off the
# Puma master (master -> supervisor -> worker). The supervisor's own hook
# fires first: it closes the handle it inherited from the master and clears
# the registry. By the time the worker forks off the supervisor there is
# nothing left in that registry for the worker's hook to discard, so the
# worker inherits a live-looking handle (closed? == false) that actually
# shares an fd it doesn't own. The next query anywhere in the process then
# raises "prepare called on a closed database" or a stray BusyException.
# closed? alone can never catch this. Keying the memo on Process.pid does:
# it forces every process — however it came to exist — to open and use only
# its own handle, never one inherited from a parent.
module ForkSafeSqlite
  def with_db
    @mutex.synchronize do
      # Never reuse a handle opened by another pid — drop the reference
      # rather than closing it (its fd may not even be ours) and open fresh.
      if @db.nil? || @db.closed? || @db_pid != Process.pid
        @db = open_database
        @db_pid = Process.pid
      end
      yield @db
    end
  end
end
