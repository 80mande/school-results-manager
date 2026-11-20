-- EduRecord billing lifecycle migration
-- Preserves existing invoice-generation and payment-review logic.
-- Adds: overdue/grace processing, academic-write restrictions, payment
-- notifications, immediate access recovery after approved payment, and
-- continued invoice generation while a subscription is suspended.
-- Time zone: Africa/Lagos.

BEGIN;

-- ---------------------------------------------------------------------
-- 0. Structured lifecycle audit history.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.school_billing_lifecycle_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL,
  subscription_id uuid,
  invoice_id uuid,
  payment_id uuid,
  event_type text NOT NULL,
  previous_status text,
  new_status text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  performed_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT school_billing_lifecycle_events_school_fk
    FOREIGN KEY (school_id) REFERENCES public.schools(id) ON DELETE CASCADE,
  CONSTRAINT school_billing_lifecycle_events_subscription_fk
    FOREIGN KEY (subscription_id, school_id)
    REFERENCES public.school_subscriptions(id, school_id)
    ON DELETE SET NULL (subscription_id),
  CONSTRAINT school_billing_lifecycle_events_invoice_fk
    FOREIGN KEY (invoice_id, school_id)
    REFERENCES public.school_billing_invoices(id, school_id)
    ON DELETE SET NULL (invoice_id),
  CONSTRAINT school_billing_lifecycle_events_payment_fk
    FOREIGN KEY (payment_id, school_id)
    REFERENCES public.school_billing_payments(id, school_id)
    ON DELETE SET NULL (payment_id),
  CONSTRAINT school_billing_lifecycle_events_actor_fk
    FOREIGN KEY (performed_by) REFERENCES public.profiles(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS school_billing_lifecycle_events_school_created_idx
  ON public.school_billing_lifecycle_events (school_id, created_at DESC);
CREATE INDEX IF NOT EXISTS school_billing_lifecycle_events_invoice_idx
  ON public.school_billing_lifecycle_events (invoice_id)
  WHERE invoice_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS school_billing_lifecycle_events_payment_idx
  ON public.school_billing_lifecycle_events (payment_id)
  WHERE payment_id IS NOT NULL;

ALTER TABLE public.school_billing_lifecycle_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.school_billing_lifecycle_events FROM anon, authenticated;
GRANT SELECT ON TABLE public.school_billing_lifecycle_events TO authenticated;
DROP POLICY IF EXISTS school_billing_lifecycle_events_reader ON public.school_billing_lifecycle_events;
CREATE POLICY school_billing_lifecycle_events_reader
  ON public.school_billing_lifecycle_events
  FOR SELECT TO authenticated
  USING (
    public.edurecord_is_owner()
    OR public.edurecord_is_school_admin(school_id)
  );

-- ---------------------------------------------------------------------
-- 1. Keep suspended subscriptions in the invoice-generation cycle.
--    This patches only the audited subscription filter and active/suspended
--    date-calculation branch. All other invoice/credit logic remains untouched.
-- ---------------------------------------------------------------------
DO $migration$
DECLARE
  v_definition text;
  v_changed boolean := false;
  v_old_filter text := 'status IN (''trial'', ''active'')';
  v_new_filter text := 'status IN (''trial'', ''active'', ''suspended'')';
  v_old_branch text := 'ELSIF v_sub.status = ''active'' THEN';
  v_new_branch text := 'ELSIF v_sub.status IN (''active'', ''suspended'') THEN';
BEGIN
  IF to_regprocedure('public.edurecord_generate_due_invoices(date)') IS NULL THEN
    RAISE EXCEPTION
      'Expected function public.edurecord_generate_due_invoices(date) was not found.';
  END IF;

  SELECT pg_get_functiondef(
    'public.edurecord_generate_due_invoices(date)'::regprocedure
  )
  INTO v_definition;

  IF strpos(v_definition, v_old_filter) > 0 THEN
    v_definition := replace(v_definition, v_old_filter, v_new_filter);
    v_changed := true;
  ELSIF strpos(v_definition, v_new_filter) = 0 THEN
    RAISE EXCEPTION
      'Invoice generator subscription filter did not match the audited definition. No changes applied.';
  END IF;

  IF strpos(v_definition, v_old_branch) > 0 THEN
    v_definition := replace(v_definition, v_old_branch, v_new_branch);
    v_changed := true;
  ELSIF strpos(v_definition, v_new_branch) = 0 THEN
    RAISE EXCEPTION
      'Invoice generator active/suspended branch did not match the audited definition. No changes applied.';
  END IF;

  IF v_changed THEN
    EXECUTE v_definition;
  END IF;
END;
$migration$;

-- ---------------------------------------------------------------------
-- 2. Central access check used by restrictive RLS policies.
--    Reads remain available. Academic writes are blocked only when an
--    invoice has an unpaid balance more than seven full days after due_at.
--    Owner access is always allowed. Schools without a subscription record
--    are not unexpectedly locked out.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.edurecord_school_subscription_allows_academic_access(
  p_school_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF COALESCE(public.edurecord_is_owner(), false) THEN
    RETURN true;
  END IF;

  IF p_school_id IS NULL
     OR p_school_id IS DISTINCT FROM public.edurecord_my_school_id() THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.school_subscriptions s
    WHERE s.school_id = p_school_id
      AND s.status = 'suspended'
  ) THEN
    RETURN false;
  END IF;

  RETURN NOT EXISTS (
    SELECT 1
    FROM public.school_billing_invoices i
    WHERE i.school_id = p_school_id
      AND i.status IN ('issued', 'partially_paid', 'overdue')
      AND i.balance_amount > 0
      AND i.due_at IS NOT NULL
      AND now() > i.due_at + interval '7 days'
  );
END;
$function$;

REVOKE ALL ON FUNCTION
  public.edurecord_school_subscription_allows_academic_access(uuid)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.edurecord_school_subscription_allows_academic_access(uuid)
TO authenticated;

-- edurecord_add_school_section is a SECURITY DEFINER RPC in the current
-- dashboard. This trigger ensures that RPC cannot bypass the subscription
-- write restriction on school_sections.
CREATE OR REPLACE FUNCTION public.edurecord_guard_school_section_writes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_school_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_school_id := OLD.school_id;
  ELSE
    v_school_id := NEW.school_id;
  END IF;

  IF NOT COALESCE(public.edurecord_is_owner(), false)
     AND NOT public.edurecord_school_subscription_allows_academic_access(v_school_id) THEN
    RAISE EXCEPTION
      'Academic operations are suspended because this school has an unpaid invoice beyond its seven-day grace period.'
      USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS edurecord_guard_school_section_writes_trigger
ON public.school_sections;

CREATE TRIGGER edurecord_guard_school_section_writes_trigger
BEFORE INSERT OR UPDATE OR DELETE ON public.school_sections
FOR EACH ROW
EXECUTE FUNCTION public.edurecord_guard_school_section_writes();

-- ---------------------------------------------------------------------
-- 3. Notification helper. Sends each event to all active school admins
--    and active EduRecord owners. Uses deterministic keys and ON CONFLICT
--    protection so the daily scheduler does not create duplicates.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.edurecord_create_billing_notifications(
  p_school_id uuid,
  p_event_type text,
  p_title text,
  p_message text,
  p_deduplication_suffix text DEFAULT NULL,
  p_related_invoice_id uuid DEFAULT NULL,
  p_related_payment_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_deduplication_key text;
  v_inserted integer := 0;
BEGIN
  IF p_school_id IS NULL
     OR p_event_type IS NULL
     OR p_title IS NULL
     OR p_message IS NULL THEN
    RAISE EXCEPTION 'School, event type, title and message are required.';
  END IF;

  v_deduplication_key :=
    'edurecord-billing:' || p_school_id::text || ':' ||
    p_event_type || ':' || COALESCE(p_deduplication_suffix, 'once');

  INSERT INTO public.school_notifications (
    school_id,
    recipient_user_id,
    recipient_role,
    event_type,
    title,
    message,
    related_invoice_id,
    related_payment_id,
    deduplication_key
  )
  SELECT
    p_school_id,
    p.id,
    'school_admin',
    p_event_type,
    p_title,
    p_message,
    p_related_invoice_id,
    p_related_payment_id,
    v_deduplication_key
  FROM public.profiles p
  WHERE p.school_id = p_school_id
    AND p.role = 'school_admin'
    AND p.is_active = true
    AND NOT EXISTS (
      SELECT 1
      FROM public.school_notifications n
      WHERE n.recipient_user_id = p.id
        AND n.deduplication_key = v_deduplication_key
    )

  UNION ALL

  SELECT
    p_school_id,
    p.id,
    'owner',
    p_event_type,
    p_title,
    p_message,
    p_related_invoice_id,
    p_related_payment_id,
    v_deduplication_key
  FROM public.profiles p
  WHERE p.role = 'owner'
    AND p.is_active = true
    AND NOT EXISTS (
      SELECT 1
      FROM public.school_notifications n
      WHERE n.recipient_user_id = p.id
        AND n.deduplication_key = v_deduplication_key
    )
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted;
END;
$function$;

REVOKE ALL ON FUNCTION public.edurecord_create_billing_notifications(
  uuid, text, text, text, text, uuid, uuid
) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Daily lifecycle processing.
--    - 7-day and 3-day upcoming due notices (catch-up safe if a run is late)
--    - due-date notice
--    - one grace-period reminder between grace days 3 and 7
--    - invoice overdue status after the due date
--    - subscription suspension only after all seven full grace days expire
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.edurecord_process_billing_lifecycle(
  p_as_of_date date DEFAULT ((now() AT TIME ZONE 'Africa/Lagos')::date)
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sub record;
  v_invoice record;
  v_last_invoice record;
  v_billing_date date;
  v_first_billing_date date;
  v_grace_end_date date;
  v_inserted integer;
  v_notification_count integer := 0;
  v_overdue_count integer := 0;
  v_suspended_count integer := 0;
BEGIN
  IF auth.uid() IS NULL
     OR NOT COALESCE(public.edurecord_is_owner(), false) THEN
    RAISE EXCEPTION 'Only the EduRecord owner can process the billing lifecycle.'
      USING ERRCODE = '42501';
  END IF;

  IF p_as_of_date IS NULL THEN
    RAISE EXCEPTION 'The lifecycle processing date cannot be null.';
  END IF;

  -- Upcoming reminders. Trial notices use the actual Lagos-local trial_end
  -- date; the first invoice is due on the first selected billing day after it.
  -- Active subscriptions use their next recurring invoice date.
  FOR v_sub IN
    SELECT
      s.id,
      s.school_id,
      s.status,
      s.trial_end,
      s.billing_day,
      s.billing_cycle
    FROM public.school_subscriptions s
    WHERE s.status IN ('trial', 'active')
      AND s.billing_day IS NOT NULL
      AND s.billing_cycle IN ('monthly', 'termly')
    ORDER BY s.school_id
  LOOP
    v_billing_date := NULL;
    v_first_billing_date := NULL;

    IF v_sub.status = 'trial' THEN
      IF v_sub.trial_end IS NOT NULL THEN
        v_billing_date :=
          (v_sub.trial_end AT TIME ZONE 'Africa/Lagos')::date;
        v_first_billing_date := public.edurecord_first_billing_date(
          v_sub.trial_end,
          v_sub.billing_day
        );
      END IF;
    ELSE
      SELECT i.period_start
      INTO v_last_invoice
      FROM public.school_billing_invoices i
      WHERE i.school_id = v_sub.school_id
        AND i.subscription_id = v_sub.id
        AND i.status <> 'cancelled'
      ORDER BY i.period_start DESC, i.created_at DESC
      LIMIT 1;

      IF FOUND THEN
        v_billing_date := public.edurecord_next_billing_date(
          v_last_invoice.period_start,
          v_sub.billing_day,
          v_sub.billing_cycle
        );
      END IF;
    END IF;

    IF v_billing_date IS NULL THEN
      CONTINUE;
    END IF;

    -- Catch up if a scheduled run missed the actual trial expiry date.
    IF v_sub.status = 'trial' AND p_as_of_date >= v_billing_date THEN
      v_inserted := public.edurecord_create_billing_notifications(
        v_sub.school_id,
        'billing_trial_expiry_date',
        CASE
          WHEN p_as_of_date = v_billing_date THEN 'Your free trial ends today'
          ELSE 'Your free trial has ended'
        END,
        'Your 14-day EduRecord free trial ' ||
          CASE
            WHEN p_as_of_date = v_billing_date THEN 'ends today ('
            ELSE 'ended on '
          END || to_char(v_billing_date, 'DD Mon YYYY') || '). ' ||
          'Your first subscription invoice is scheduled for ' ||
          to_char(v_first_billing_date, 'DD Mon YYYY') ||
          '. Please arrange payment when the invoice is issued.',
        'trial-expiry:' || to_char(v_billing_date, 'YYYYMMDD'),
        NULL,
        NULL
      );
      v_notification_count := v_notification_count + v_inserted;
      CONTINUE;
    END IF;

    IF v_billing_date <= p_as_of_date THEN
      CONTINUE;
    END IF;

    IF p_as_of_date >= v_billing_date - 3 THEN
      IF v_sub.status = 'trial' THEN
        v_inserted := public.edurecord_create_billing_notifications(
          v_sub.school_id,
          'billing_trial_ends_3_days',
          'Your free trial ends in 3 days',
          'Your 14-day EduRecord free trial ends on ' ||
            to_char(v_billing_date, 'DD Mon YYYY') ||
            '. Your first subscription invoice is scheduled for ' ||
            to_char(v_first_billing_date, 'DD Mon YYYY') || '.',
          'trial-expiry:' || to_char(v_billing_date, 'YYYYMMDD'),
          NULL,
          NULL
        );
      ELSE
        v_inserted := public.edurecord_create_billing_notifications(
          v_sub.school_id,
          'billing_due_3_days',
          'Subscription payment due soon',
          'Your next EduRecord subscription payment is due on ' ||
            to_char(v_billing_date, 'DD Mon YYYY') ||
            '. Please arrange payment before the due date to avoid entering the grace period.',
          'due:' || to_char(v_billing_date, 'YYYYMMDD'),
          NULL,
          NULL
        );
      END IF;
      v_notification_count := v_notification_count + v_inserted;
    ELSIF p_as_of_date >= v_billing_date - 7 THEN
      IF v_sub.status = 'trial' THEN
        v_inserted := public.edurecord_create_billing_notifications(
          v_sub.school_id,
          'billing_trial_ends_7_days',
          'Your free trial ends in 7 days',
          'Your 14-day EduRecord free trial ends on ' ||
            to_char(v_billing_date, 'DD Mon YYYY') ||
            '. Your first subscription invoice is scheduled for ' ||
            to_char(v_first_billing_date, 'DD Mon YYYY') || '.',
          'trial-expiry:' || to_char(v_billing_date, 'YYYYMMDD'),
          NULL,
          NULL
        );
      ELSE
        v_inserted := public.edurecord_create_billing_notifications(
          v_sub.school_id,
          'billing_due_7_days',
          'Subscription payment due in the coming week',
          'Your next EduRecord subscription payment is due on ' ||
            to_char(v_billing_date, 'DD Mon YYYY') ||
            '. Please prepare payment to avoid interruption to academic operations.',
          'due:' || to_char(v_billing_date, 'YYYYMMDD'),
          NULL,
          NULL
        );
      END IF;
      v_notification_count := v_notification_count + v_inserted;
    END IF;
  END LOOP;

  -- Due-date reminders for invoices generated earlier in this same run.
  FOR v_invoice IN
    SELECT
      i.id,
      i.school_id,
      i.invoice_number
    FROM public.school_billing_invoices i
    WHERE i.period_start = p_as_of_date
      AND i.status IN ('issued', 'partially_paid', 'overdue')
      AND i.balance_amount > 0
    ORDER BY i.school_id, i.created_at
  LOOP
    v_inserted := public.edurecord_create_billing_notifications(
      v_invoice.school_id,
      'billing_due_today',
      'Subscription invoice due today',
      'Your EduRecord invoice ' || COALESCE(v_invoice.invoice_number, '') ||
        ' is due today. Payment is due by 11:59 p.m. Nigeria time. ' ||
        'Any unpaid balance then enters the seven-day grace period.',
      'invoice:' || v_invoice.id::text,
      v_invoice.id,
      NULL
    );
    v_notification_count := v_notification_count + v_inserted;
  END LOOP;

  -- One grace reminder, issued on the first scheduler run from grace day 3
  -- through the final grace day. Payments do not suppress suspension unless
  -- they are approved and actually clear all matured overdue balances.
  FOR v_invoice IN
    SELECT
      i.id,
      i.school_id,
      i.invoice_number,
      (i.due_at AT TIME ZONE 'Africa/Lagos')::date AS due_date
    FROM public.school_billing_invoices i
    WHERE i.status IN ('issued', 'partially_paid', 'overdue')
      AND i.balance_amount > 0
      AND i.due_at IS NOT NULL
      AND p_as_of_date BETWEEN
        ((i.due_at AT TIME ZONE 'Africa/Lagos')::date + 3)
        AND ((i.due_at AT TIME ZONE 'Africa/Lagos')::date + 7)
    ORDER BY i.school_id, i.due_at
  LOOP
    v_grace_end_date := v_invoice.due_date + 7;

    v_inserted := public.edurecord_create_billing_notifications(
      v_invoice.school_id,
      'billing_grace_reminder',
      'Payment grace period reminder',
      'Invoice ' || COALESCE(v_invoice.invoice_number, '') ||
        ' remains unpaid. Your seven-day grace period ends at 11:59 p.m. ' ||
        'Nigeria time on ' || to_char(v_grace_end_date, 'DD Mon YYYY') ||
        '. Academic access will be suspended after that if the balance remains unpaid.',
      'invoice:' || v_invoice.id::text,
      v_invoice.id,
      NULL
    );
    v_notification_count := v_notification_count + v_inserted;
  END LOOP;

  -- Mark invoices overdue from the start of the day after their due date
  -- and retain an immutable lifecycle audit row for each status transition.
  WITH due_invoices AS MATERIALIZED (
    SELECT i.id, i.school_id, i.status AS previous_status
    FROM public.school_billing_invoices i
    WHERE i.status IN ('issued', 'partially_paid')
      AND i.balance_amount > 0
      AND i.due_at IS NOT NULL
      AND i.due_at < (p_as_of_date::timestamp AT TIME ZONE 'Africa/Lagos')
    FOR UPDATE
  ), updated_invoices AS (
    UPDATE public.school_billing_invoices i
    SET status = 'overdue', updated_at = now()
    FROM due_invoices d
    WHERE i.id = d.id
    RETURNING i.id, i.school_id
  )
  INSERT INTO public.school_billing_lifecycle_events (
    school_id, invoice_id, event_type, previous_status, new_status,
    details, performed_by
  )
  SELECT
    u.school_id,
    u.id,
    'invoice_marked_overdue',
    d.previous_status,
    'overdue',
    jsonb_build_object('as_of_date', p_as_of_date),
    auth.uid()
  FROM updated_invoices u
  JOIN due_invoices d ON d.id = u.id;

  GET DIAGNOSTICS v_overdue_count = ROW_COUNT;

  -- Suspend once a school has at least one unpaid invoice whose due date
  -- plus seven full Lagos calendar days is earlier than the processing date.
  FOR v_sub IN
    SELECT s.id, s.school_id, s.status AS previous_status
    FROM public.school_subscriptions s
    WHERE s.status IN ('trial', 'active')
    ORDER BY s.school_id
    FOR UPDATE
  LOOP
    SELECT
      i.id,
      i.invoice_number,
      (i.due_at AT TIME ZONE 'Africa/Lagos')::date AS due_date
    INTO v_invoice
    FROM public.school_billing_invoices i
    WHERE i.school_id = v_sub.school_id
      AND i.status IN ('issued', 'partially_paid', 'overdue')
      AND i.balance_amount > 0
      AND i.due_at IS NOT NULL
      AND ((i.due_at AT TIME ZONE 'Africa/Lagos')::date + 7) < p_as_of_date
    ORDER BY i.due_at, i.created_at
    LIMIT 1;

    IF FOUND THEN
      UPDATE public.school_subscriptions
      SET status = 'suspended'
      WHERE id = v_sub.id
        AND status IN ('trial', 'active');

      IF FOUND THEN
        v_suspended_count := v_suspended_count + 1;

        INSERT INTO public.school_billing_lifecycle_events (
          school_id, subscription_id, invoice_id, event_type,
          previous_status, new_status, details, performed_by
        )
        VALUES (
          v_sub.school_id,
          v_sub.id,
          v_invoice.id,
          'subscription_suspended',
          v_sub.previous_status,
          'suspended',
          jsonb_build_object(
            'reason', 'unpaid_invoice_after_seven_day_grace',
            'invoice_number', v_invoice.invoice_number,
            'grace_end_date', v_invoice.due_date + 7
          ),
          auth.uid()
        );

        v_inserted := public.edurecord_create_billing_notifications(
          v_sub.school_id,
          'billing_access_suspended',
          'Academic operations suspended',
          'Academic operations have been suspended because invoice ' ||
            COALESCE(v_invoice.invoice_number, '') ||
            ' remains unpaid after the full seven-day grace period. ' ||
            'Submit payment evidence and contact EduRecord for review. Access is restored after approved payment clears all invoices that have passed the grace period.',
          'invoice:' || v_invoice.id::text,
          v_invoice.id,
          NULL
        );
        v_notification_count := v_notification_count + v_inserted;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'as_of_date', p_as_of_date,
    'notifications_created', v_notification_count,
    'invoices_marked_overdue', v_overdue_count,
    'subscriptions_suspended', v_suspended_count
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.edurecord_process_billing_lifecycle(date)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.edurecord_create_billing_notifications(
  uuid, text, text, text, text, uuid, uuid
) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Payment status trigger.
--    The existing edurecord_review_billing_payment function is preserved.
--    When it changes a payment from pending to approved/rejected, this
--    trigger notifies both parties. Approved payments restore a suspended
--    school immediately only if no invoice still exceeds its grace period.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.edurecord_handle_billing_payment_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_invoice_id uuid;
  v_subscription_id uuid;
  v_restored_rows integer := 0;
  v_amount_text text;
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status
     AND OLD.status = 'pending' THEN

    v_invoice_id := NEW.invoice_id;

    -- Advance payments may have a NULL invoice_id. Resolve the invoice from
    -- the credit-application ledger without changing the existing payment row.
    IF v_invoice_id IS NULL AND NEW.status = 'approved' THEN
      SELECT ca.invoice_id
      INTO v_invoice_id
      FROM public.school_billing_credits c
      JOIN public.school_billing_credit_applications ca
        ON ca.credit_id = c.id
       AND ca.school_id = c.school_id
      WHERE c.payment_id = NEW.id
        AND c.school_id = NEW.school_id
      ORDER BY ca.created_at, ca.id
      LIMIT 1;
    END IF;

    SELECT s.id
    INTO v_subscription_id
    FROM public.school_subscriptions s
    WHERE s.school_id = NEW.school_id;

    IF NEW.status = 'approved' THEN
      v_amount_text := to_char(NEW.amount, 'FM999999999990.00');

      INSERT INTO public.school_billing_lifecycle_events (
        school_id, subscription_id, invoice_id, payment_id, event_type,
        previous_status, new_status, details, performed_by
      )
      VALUES (
        NEW.school_id, v_subscription_id, v_invoice_id, NEW.id,
        'payment_approved', OLD.status, NEW.status,
        jsonb_build_object(
          'amount', NEW.amount,
          'receipt_number', NEW.receipt_number,
          'transaction_reference', NEW.transaction_reference
        ),
        NEW.reviewed_by
      );

      -- Restore only when all invoices that have passed their grace period
      -- have zero outstanding balance. Pending payments do not qualify.
      UPDATE public.school_subscriptions s
      SET status = 'active'
      WHERE s.school_id = NEW.school_id
        AND s.status = 'suspended'
        AND NOT EXISTS (
          SELECT 1
          FROM public.school_billing_invoices i
          WHERE i.school_id = NEW.school_id
            AND i.status IN ('issued', 'partially_paid', 'overdue')
            AND i.balance_amount > 0
            AND i.due_at IS NOT NULL
            AND now() > i.due_at + interval '7 days'
        );

      GET DIAGNOSTICS v_restored_rows = ROW_COUNT;

      IF v_restored_rows > 0 THEN
        INSERT INTO public.school_billing_lifecycle_events (
          school_id, subscription_id, invoice_id, payment_id, event_type,
          previous_status, new_status, details, performed_by
        )
        VALUES (
          NEW.school_id, v_subscription_id, v_invoice_id, NEW.id,
          'subscription_access_restored', 'suspended', 'active',
          jsonb_build_object('reason', 'approved_payment_cleared_matured_balance'),
          NEW.reviewed_by
        );
      END IF;

      PERFORM public.edurecord_create_billing_notifications(
        NEW.school_id,
        'billing_payment_approved',
        'Payment approved',
        'Your payment of ₦' || v_amount_text ||
          ' has been approved. Receipt number: ' ||
          COALESCE(NEW.receipt_number, 'not available') ||
          '. Any remaining approved credit will be handled under the existing billing rules.',
        'payment:' || NEW.id::text,
        v_invoice_id,
        NEW.id
      );

      IF v_restored_rows > 0 THEN
        PERFORM public.edurecord_create_billing_notifications(
          NEW.school_id,
          'billing_access_restored',
          'Academic access restored',
          'Academic access has been restored because approved payment has cleared all invoices that had passed the seven-day grace period.',
          'payment:' || NEW.id::text,
          v_invoice_id,
          NEW.id
        );
      END IF;

    ELSIF NEW.status = 'rejected' THEN
      INSERT INTO public.school_billing_lifecycle_events (
        school_id, subscription_id, invoice_id, payment_id, event_type,
        previous_status, new_status, details, performed_by
      )
      VALUES (
        NEW.school_id, v_subscription_id, v_invoice_id, NEW.id,
        'payment_rejected', OLD.status, NEW.status,
        jsonb_build_object('rejection_reason', NEW.rejection_reason),
        NEW.reviewed_by
      );

      PERFORM public.edurecord_create_billing_notifications(
        NEW.school_id,
        'billing_payment_rejected',
        'Payment submission rejected',
        'Your payment submission was rejected. Reason: ' ||
          COALESCE(NULLIF(btrim(NEW.rejection_reason), ''), 'Please contact EduRecord for details.'),
        'payment:' || NEW.id::text,
        v_invoice_id,
        NEW.id
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS edurecord_billing_payment_lifecycle_trigger
ON public.school_billing_payments;

CREATE TRIGGER edurecord_billing_payment_lifecycle_trigger
AFTER UPDATE OF status ON public.school_billing_payments
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION public.edurecord_handle_billing_payment_status_change();

-- ---------------------------------------------------------------------
-- 6. Update the scheduled RPC orchestration.
--    The existing scheduled-billing Edge Function continues to call this
--    RPC. It does not need a code replacement or redeployment.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.edurecord_run_scheduled_billing(
  p_as_of_date date DEFAULT ((now() AT TIME ZONE 'Africa/Lagos')::date)
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_owner_id uuid;
  v_owner_count integer;
  v_previous_sub text;
  v_invoice_result jsonb;
  v_lifecycle_result jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'Unauthorized scheduled billing request.';
  END IF;

  SELECT COUNT(*), MIN(id::text)::uuid
  INTO v_owner_count, v_owner_id
  FROM public.profiles
  WHERE role = 'owner'
    AND is_active = true;

  IF v_owner_count <> 1 THEN
    RAISE EXCEPTION
      'Scheduled billing requires exactly one active owner.';
  END IF;

  v_previous_sub := current_setting('request.jwt.claim.sub', true);

  PERFORM set_config(
    'request.jwt.claim.sub',
    v_owner_id::text,
    true
  );

  BEGIN
    v_invoice_result :=
      public.edurecord_generate_due_invoices(p_as_of_date);

    v_lifecycle_result :=
      public.edurecord_process_billing_lifecycle(p_as_of_date);

  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config(
      'request.jwt.claim.sub',
      COALESCE(v_previous_sub, ''),
      true
    );
    RAISE;
  END;

  PERFORM set_config(
    'request.jwt.claim.sub',
    COALESCE(v_previous_sub, ''),
    true
  );

  RETURN jsonb_build_object(
    'success', true,
    'as_of_date', p_as_of_date,
    'invoice_result', v_invoice_result,
    'lifecycle_result', v_lifecycle_result
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.edurecord_run_scheduled_billing(date)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edurecord_run_scheduled_billing(date)
TO service_role;

-- ---------------------------------------------------------------------
-- 7. Restrict academic INSERT/UPDATE/DELETE operations while suspended.
--    SELECT policies are deliberately untouched so admins and teachers
--    can continue viewing existing records, invoices and notifications.
--    Billing and school-website tables are deliberately excluded.
-- ---------------------------------------------------------------------
DO $policies$
DECLARE
  v_table text;
  v_tables text[] := ARRAY[
    'academic_terms',
    'assessment_settings',
    'class_subjects',
    'classes',
    'result_publications',
    'results',
    'school_sections',
    'school_settings',
    'scores',
    'section_score_settings',
    'students',
    'subjects',
    'teacher_assignments',
    'teacher_score_submissions'
  ];
BEGIN
  FOREACH v_table IN ARRAY v_tables LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS edurecord_subscription_write_insert ON public.%I',
      v_table
    );
    EXECUTE format(
      'CREATE POLICY edurecord_subscription_write_insert ON public.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (public.edurecord_is_owner() OR public.edurecord_school_subscription_allows_academic_access(school_id))',
      v_table
    );

    EXECUTE format(
      'DROP POLICY IF EXISTS edurecord_subscription_write_update ON public.%I',
      v_table
    );
    EXECUTE format(
      'CREATE POLICY edurecord_subscription_write_update ON public.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING (public.edurecord_is_owner() OR public.edurecord_school_subscription_allows_academic_access(school_id)) WITH CHECK (public.edurecord_is_owner() OR public.edurecord_school_subscription_allows_academic_access(school_id))',
      v_table
    );

    EXECUTE format(
      'DROP POLICY IF EXISTS edurecord_subscription_write_delete ON public.%I',
      v_table
    );
    EXECUTE format(
      'CREATE POLICY edurecord_subscription_write_delete ON public.%I AS RESTRICTIVE FOR DELETE TO authenticated USING (public.edurecord_is_owner() OR public.edurecord_school_subscription_allows_academic_access(school_id))',
      v_table
    );
  END LOOP;
END;
$policies$;

COMMIT;

-- ---------------------------------------------------------------------
-- 8. Read-only verification output.
-- ---------------------------------------------------------------------
SELECT
  'invoice_generator_handles_suspended' AS check_name,
  (
    pg_get_functiondef(
      'public.edurecord_generate_due_invoices(date)'::regprocedure
    ) ILIKE '%status IN (''trial'', ''active'', ''suspended'')%'
    AND pg_get_functiondef(
      'public.edurecord_generate_due_invoices(date)'::regprocedure
    ) ILIKE '%ELSIF v_sub.status IN (''active'', ''suspended'') THEN%'
  ) AS passed;

SELECT
  'scheduled_rpc_service_role_only' AS check_name,
  has_function_privilege(
    'service_role',
    'public.edurecord_run_scheduled_billing(date)',
    'EXECUTE'
  ) AS service_role_can_execute,
  has_function_privilege(
    'authenticated',
    'public.edurecord_run_scheduled_billing(date)',
    'EXECUTE'
  ) AS authenticated_can_execute,
  has_function_privilege(
    'anon',
    'public.edurecord_run_scheduled_billing(date)',
    'EXECUTE'
  ) AS anon_can_execute;

SELECT
  tablename,
  count(*) FILTER (WHERE policyname LIKE 'edurecord_subscription_write_%')
    AS lifecycle_restrictive_policy_count
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
    'academic_terms', 'assessment_settings', 'class_subjects', 'classes',
    'result_publications', 'results', 'school_sections', 'school_settings',
    'scores', 'section_score_settings', 'students', 'subjects',
    'teacher_assignments', 'teacher_score_submissions'
  )
GROUP BY tablename
ORDER BY tablename;

SELECT
  s.school_id,
  s.status AS subscription_status,
  EXISTS (
    SELECT 1
    FROM public.school_billing_invoices i
    WHERE i.school_id = s.school_id
      AND i.status IN ('issued', 'partially_paid', 'overdue')
      AND i.balance_amount > 0
      AND i.due_at IS NOT NULL
      AND now() > i.due_at + interval '7 days'
  ) AS has_unpaid_invoice_past_grace
FROM public.school_subscriptions s
ORDER BY s.school_id;

SELECT
  'billing_lifecycle_audit_ledger' AS check_name,
  to_regclass('public.school_billing_lifecycle_events') IS NOT NULL AS table_exists,
  (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'school_billing_lifecycle_events') AS index_count;
