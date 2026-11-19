Metric definitions:
     * SLA clocks are wall-clock time. They do NOT pause while waiting on the customer.
     * First response time = created_at -> first_response_at, in minutes.
     * Resolution time     = created_at -> resolved_at, in minutes.
     * Breach rates only count tickets where the event happened (no response yet = not measured).
     * Tickets with resolved_at before created_at are excluded (flagged in Step 4 DQ checks).
      keys are informational in Snowflake (not enforced),
--    but they document the model and BI tools read them.
