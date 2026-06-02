# frozen_string_literal: true

module McptaskRunner
  # Authoritative, REST-only daily-quota gate. No AI-agent self-report involved.
  #
  # Reads worked_today / per_day straight from mcptask.online via TimeStatusClient
  # (the same numbers the UI shows) and decides whether the daily quota is spent.
  # This is the single source of truth for every quota guard in the runner — the
  # pre-run check, the between-task loop check, and the mid-task heartbeat.
  #
  # Fail-closed: any REST failure is reported as `exceeded` so the runner stops
  # rather than risk a silent overrun on missing data. Callers that must not
  # freeze the whole day on a transient blip (e.g. "is today a working day?")
  # inspect `rest_ok` and decide their own fallback.
  class QuotaGuard
    Status = Struct.new(:exceeded, :worked_today, :per_day, :rest_ok, keyword_init: true)

    class << self
      def status
        new.status
      end

      # Delegates to .status so a single stub point (QuotaGuard.status) drives both.
      def exceeded?
        status.exceeded
      end
    end

    def status
      truth = TimeStatusClient.fetch
      build_status(truth[:worked_today], truth[:per_day], rest_ok: true)
    rescue TimeStatusClient::Error => e
      Logger.warn("[QuotaGuard] REST quota fetch failed (#{e.message}); fail-closed → treating quota as exceeded")
      build_status(nil, nil, rest_ok: false)
    end

    private

    def build_status(worked, per_day, rest_ok:)
      exceeded = !rest_ok || !per_day.positive? || worked >= per_day
      Logger.debug("[QuotaGuard] worked_today=#{worked.inspect}h per_day=#{per_day.inspect}h rest_ok=#{rest_ok} exceeded=#{exceeded}")
      Status.new(exceeded: exceeded, worked_today: worked, per_day: per_day, rest_ok: rest_ok)
    end
  end
end
