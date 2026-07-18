# Runs a block in a forked child process and reports back whatever it
# returns, Marshal'd over a pipe — the fork-safety regression specs need to
# observe SQLite handle state *inside* the child (a plain in-process double
# can't fake that). Bounded with a deadline so a wedged child — e.g. this
# box's shared SQLite files are also touched by another process — fails the
# example instead of hanging the whole suite.
module ForkProbe
  module_function

  def run(deadline: 15)
    reader, writer = IO.pipe
    reader.binmode
    writer.binmode

    pid = fork do
      reader.close
      result =
        begin
          { ok: true, value: yield }
        rescue StandardError => e
          { ok: false, error: "#{e.class}: #{e.message}" }
        end
      writer.write(Marshal.dump(result))
      writer.close
      exit!(true)
    end
    writer.close

    data = IO.select([ reader ], nil, nil, deadline) ? reader.read : nil
    reader.close

    if data.nil? || data.empty?
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
      Process.waitpid(pid)
      return { ok: false, error: "child did not respond within #{deadline}s" }
    end

    Process.waitpid(pid)
    Marshal.load(data) # rubocop:disable Security/MarshalLoad -- trusted child of this same process
  end
end
