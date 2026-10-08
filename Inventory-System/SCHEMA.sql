-- ============================================================
-- PHARMACY ROBOT INVENTORY — SCHEMA (v3)
-- Supabase / PostgreSQL 15+
--
-- One Supabase project = one pharmacy = ONE robot.
--
-- Access model:
--   * The pharmacy backend connects with service_role. It is the only
--     writer and the only reader. The robot is also a service_role client.
--   * anon and authenticated have NO access to any table or function.
--   * Every state change happens in a function; tables are never written directly.
--   * The backend passes p_actor (who triggered the action, from its own login)
--     into every operator function. It is recorded as text, not verified here.
--
-- Flow:
--   register prescription -> add items -> verify
--     -> plan pick (allocate bins FEFO, reserve stock, create task)
--     -> robot claims task -> robot picks each reservation
--     -> task completes -> prescription READY
--     -> dispense -> COMPLETED
-- ============================================================


-- ============================================================
-- 1. CATALOG AND PHYSICAL LOCATIONS
-- ============================================================

CREATE TABLE public.medicines (
    medicine_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                  VARCHAR(255) NOT NULL,
    generic_name          VARCHAR(255),
    brand_name            VARCHAR(255),
    strength              VARCHAR(100),
    dosage_form           VARCHAR(100),
    manufacturer          VARCHAR(255),
    barcode               VARCHAR(100),
    requires_prescription BOOLEAN NOT NULL DEFAULT FALSE,
    description           TEXT,
    is_active             BOOLEAN NOT NULL DEFAULT TRUE,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX medicines_barcode_unique
    ON public.medicines(barcode) WHERE barcode IS NOT NULL;
CREATE INDEX medicines_name_idx ON public.medicines(name);
CREATE INDEX medicines_generic_name_idx ON public.medicines(generic_name);


CREATE TABLE public.racks (
    rack_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rack_number         VARCHAR(50) NOT NULL UNIQUE,
    zone                VARCHAR(100),
    x_coordinate        DECIMAL(10, 2) NOT NULL DEFAULT 0,
    y_coordinate        DECIMAL(10, 2) NOT NULL DEFAULT 0,
    orientation_degrees DECIMAL(6, 2) NOT NULL DEFAULT 0,
    width_cm            DECIMAL(10, 2),
    depth_cm            DECIMAL(10, 2),
    height_cm           DECIMAL(10, 2),
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX racks_zone_idx ON public.racks(zone);


CREATE TABLE public.shelves (
    shelf_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rack_id       UUID NOT NULL REFERENCES public.racks(rack_id) ON DELETE RESTRICT,
    shelf_number  INTEGER NOT NULL,
    height_cm     DECIMAL(10, 2) NOT NULL,
    width_cm      DECIMAL(10, 2),
    depth_cm      DECIMAL(10, 2),
    max_weight_kg DECIMAL(10, 2),
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT shelves_unique_per_rack UNIQUE (rack_id, shelf_number),
    CONSTRAINT shelves_number_positive CHECK (shelf_number > 0),
    CONSTRAINT shelves_height_nonneg CHECK (height_cm >= 0)
);

CREATE INDEX shelves_rack_idx ON public.shelves(rack_id);


-- ============================================================
-- 2. INVENTORY
-- ============================================================
-- One row = one physical bin holding one batch of one medicine.
-- A bin holds one batch at a time. Rows are never deleted.
-- ============================================================

CREATE TABLE public.inventory (
    inventory_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    medicine_id         UUID NOT NULL REFERENCES public.medicines(medicine_id) ON DELETE RESTRICT,
    shelf_id            UUID NOT NULL REFERENCES public.shelves(shelf_id) ON DELETE RESTRICT,
    bin_code            VARCHAR(50) NOT NULL,
    batch_number        VARCHAR(100) NOT NULL,
    quantity            INTEGER NOT NULL DEFAULT 0,
    reserved_quantity   INTEGER NOT NULL DEFAULT 0,
    low_stock_threshold INTEGER NOT NULL DEFAULT 5,
    expiry_date         DATE,
    is_blocked          BOOLEAN NOT NULL DEFAULT FALSE,
    block_reason        TEXT,
    unit_weight_grams   DECIMAL(10, 2),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT inventory_one_batch_per_bin UNIQUE (shelf_id, bin_code),
    CONSTRAINT inventory_quantity_nonneg CHECK (quantity >= 0),
    CONSTRAINT inventory_reserved_nonneg CHECK (reserved_quantity >= 0),
    CONSTRAINT inventory_reserved_le_quantity CHECK (reserved_quantity <= quantity),
    CONSTRAINT inventory_threshold_nonneg CHECK (low_stock_threshold >= 0),
    CONSTRAINT inventory_block_reason CHECK (is_blocked = FALSE OR block_reason IS NOT NULL)
);

CREATE INDEX inventory_medicine_idx ON public.inventory(medicine_id);
CREATE INDEX inventory_expiry_idx ON public.inventory(expiry_date);
CREATE INDEX inventory_available_lookup_idx
    ON public.inventory(medicine_id, is_blocked, expiry_date);


-- ============================================================
-- 3. PRESCRIPTIONS
-- ============================================================
-- No patient data. rx_number is the pharmacy's own reference.
-- verified_by / dispensed_by / cancelled_by are the operator name
-- supplied by the backend (free text, not a foreign key).
-- ============================================================

CREATE TABLE public.prescriptions (
    prescription_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rx_number       VARCHAR(100) NOT NULL UNIQUE,
    prescriber_name VARCHAR(255),
    status          VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING', 'PROCESSING', 'READY', 'COMPLETED', 'CANCELLED')),
    notes           TEXT,

    received_by     TEXT NOT NULL,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    verified_by     TEXT,
    verified_at     TIMESTAMPTZ,

    dispensed_by    TEXT,
    dispensed_at    TIMESTAMPTZ,

    cancelled_by    TEXT,
    cancelled_at    TIMESTAMPTZ,
    cancel_reason   TEXT,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT prescriptions_verified_pair
        CHECK ((verified_by IS NULL) = (verified_at IS NULL)),
    CONSTRAINT prescriptions_dispensed_pair
        CHECK ((dispensed_by IS NULL) = (dispensed_at IS NULL)),
    CONSTRAINT prescriptions_dispensed_needs_verified
        CHECK (dispensed_at IS NULL OR verified_at IS NOT NULL),
    CONSTRAINT prescriptions_completed_needs_dispense
        CHECK (status <> 'COMPLETED' OR dispensed_at IS NOT NULL),
    CONSTRAINT prescriptions_cancel_fields
        CHECK (status <> 'CANCELLED' OR (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL))
);

CREATE INDEX prescriptions_status_idx ON public.prescriptions(status);
CREATE INDEX prescriptions_received_idx ON public.prescriptions(received_at);


CREATE TABLE public.prescription_items (
    prescription_item_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    prescription_id      UUID NOT NULL REFERENCES public.prescriptions(prescription_id) ON DELETE RESTRICT,
    medicine_id          UUID NOT NULL REFERENCES public.medicines(medicine_id) ON DELETE RESTRICT,
    quantity_required    INTEGER NOT NULL,
    dosage_instructions  TEXT,
    -- PICKED = robot has picked the full quantity (not yet dispensed)
    status               VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                         CHECK (status IN ('PENDING', 'RESERVED', 'PICKED', 'UNAVAILABLE', 'CANCELLED')),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT prescription_items_quantity_positive CHECK (quantity_required > 0)
);

CREATE INDEX prescription_items_prescription_idx ON public.prescription_items(prescription_id);
CREATE INDEX prescription_items_medicine_idx ON public.prescription_items(medicine_id);


-- ============================================================
-- 4. ROBOT TASKS
-- ============================================================
-- Lifecycle (enforced by trigger):
--   QUEUED -> ASSIGNED -> IN_PROGRESS -> COMPLETED
--   QUEUED -> CANCELLED
--   ASSIGNED -> CANCELLED | FAILED
--   IN_PROGRESS -> FAILED
-- ============================================================

CREATE TABLE public.robot_tasks (
    task_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    prescription_id UUID REFERENCES public.prescriptions(prescription_id) ON DELETE RESTRICT,
    task_type       VARCHAR(20) NOT NULL
                    CHECK (task_type IN ('PICK_MEDICINE', 'RETURN_MEDICINE', 'RESTOCK', 'INVENTORY_SCAN')),
    priority        INTEGER NOT NULL DEFAULT 5 CHECK (priority BETWEEN 0 AND 10),
    status          VARCHAR(20) NOT NULL DEFAULT 'QUEUED'
                    CHECK (status IN ('QUEUED', 'ASSIGNED', 'IN_PROGRESS', 'COMPLETED', 'FAILED', 'CANCELLED')),
    error_message   TEXT,
    start_x         DECIMAL(10, 2),
    start_y         DECIMAL(10, 2),
    end_x           DECIMAL(10, 2),
    end_y           DECIMAL(10, 2),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    assigned_at     TIMESTAMPTZ,
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT robot_tasks_pick_needs_prescription
        CHECK (task_type <> 'PICK_MEDICINE' OR prescription_id IS NOT NULL)
);

CREATE INDEX robot_tasks_queue_idx
    ON public.robot_tasks(priority DESC, created_at) WHERE status = 'QUEUED';
CREATE INDEX robot_tasks_prescription_idx ON public.robot_tasks(prescription_id);


-- ============================================================
-- 5. ROBOT (SINGLE ROBOT)
-- ============================================================
-- Exactly one row (robot_id = 1).
-- active_task_id guarantees at most one task in flight.
--   BUSY is set only by claim, and only while a task is active.
--   IDLE is allowed only while no task is active.
-- ============================================================

CREATE TABLE public.robot (
    robot_id        SMALLINT PRIMARY KEY DEFAULT 1 CHECK (robot_id = 1),
    robot_name      VARCHAR(100) NOT NULL,
    model           VARCHAR(100),
    serial_number   VARCHAR(150),
    status          VARCHAR(20) NOT NULL DEFAULT 'OFFLINE'
                    CHECK (status IN ('IDLE', 'BUSY', 'CHARGING', 'ERROR', 'OFFLINE', 'MAINTENANCE')),
    active_task_id  UUID UNIQUE REFERENCES public.robot_tasks(task_id) ON DELETE SET NULL,
    current_x       DECIMAL(10, 2),
    current_y       DECIMAL(10, 2),
    current_z       DECIMAL(10, 2),
    battery_percent DECIMAL(5, 2),
    last_seen_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT robot_battery_range
        CHECK (battery_percent IS NULL OR battery_percent BETWEEN 0 AND 100),
    CONSTRAINT robot_idle_means_no_task
        CHECK (status <> 'IDLE' OR active_task_id IS NULL),
    CONSTRAINT robot_busy_means_task
        CHECK (status <> 'BUSY' OR active_task_id IS NOT NULL)
);


-- ============================================================
-- 6. ROBOT TASK ITEMS (one per bin pick)
-- ============================================================

CREATE TABLE public.robot_task_items (
    task_item_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id              UUID NOT NULL REFERENCES public.robot_tasks(task_id) ON DELETE RESTRICT,
    prescription_item_id UUID REFERENCES public.prescription_items(prescription_item_id) ON DELETE RESTRICT,
    medicine_id          UUID NOT NULL REFERENCES public.medicines(medicine_id) ON DELETE RESTRICT,
    inventory_id         UUID NOT NULL REFERENCES public.inventory(inventory_id) ON DELETE RESTRICT,
    quantity_requested   INTEGER NOT NULL,
    quantity_picked      INTEGER NOT NULL DEFAULT 0,
    status               VARCHAR(20) NOT NULL DEFAULT 'RESERVED'
                         CHECK (status IN ('RESERVED', 'PICKED', 'CANCELLED')),

    -- location snapshot taken at planning time
    rack_id                    UUID NOT NULL REFERENCES public.racks(rack_id) ON DELETE RESTRICT,
    shelf_id                   UUID NOT NULL REFERENCES public.shelves(shelf_id) ON DELETE RESTRICT,
    rack_number                VARCHAR(50) NOT NULL,
    shelf_number               INTEGER NOT NULL,
    bin_code                   VARCHAR(50) NOT NULL,
    target_x                   DECIMAL(10, 2) NOT NULL,
    target_y                   DECIMAL(10, 2) NOT NULL,
    target_height_cm           DECIMAL(10, 2) NOT NULL,
    target_orientation_degrees DECIMAL(6, 2) NOT NULL,

    picked_at    TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT rti_quantity_requested_positive CHECK (quantity_requested > 0),
    CONSTRAINT rti_quantity_picked_range
        CHECK (quantity_picked BETWEEN 0 AND quantity_requested),
    CONSTRAINT rti_picked_consistency
        CHECK (
            (status = 'PICKED' AND picked_at IS NOT NULL AND quantity_picked = quantity_requested)
            OR (status <> 'PICKED' AND picked_at IS NULL)
        )
);

CREATE INDEX robot_task_items_task_idx ON public.robot_task_items(task_id);
CREATE INDEX robot_task_items_inventory_idx ON public.robot_task_items(inventory_id);
CREATE INDEX robot_task_items_prescription_item_idx
    ON public.robot_task_items(prescription_item_id);
CREATE INDEX robot_task_items_status_idx ON public.robot_task_items(status);


-- ============================================================
-- 7. RESERVATIONS
-- ============================================================
-- One reservation per task item. inventory.reserved_quantity equals the
-- sum of ACTIVE reservations for that row. Only functions change either side.
-- ============================================================

CREATE TABLE public.reservations (
    reservation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_item_id   UUID NOT NULL UNIQUE REFERENCES public.robot_task_items(task_item_id) ON DELETE RESTRICT,
    inventory_id   UUID NOT NULL REFERENCES public.inventory(inventory_id) ON DELETE RESTRICT,
    quantity       INTEGER NOT NULL,
    status         VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                   CHECK (status IN ('ACTIVE', 'CONSUMED', 'RELEASED')),
    expires_at     TIMESTAMPTZ NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at    TIMESTAMPTZ,
    CONSTRAINT reservations_quantity_positive CHECK (quantity > 0),
    CONSTRAINT reservations_resolved_consistency
        CHECK ((status = 'ACTIVE') = (resolved_at IS NULL))
);

CREATE INDEX reservations_active_expiry_idx
    ON public.reservations(expires_at) WHERE status = 'ACTIVE';
CREATE INDEX reservations_inventory_idx ON public.reservations(inventory_id);


-- ============================================================
-- 8. INVENTORY MOVEMENTS (append-only ledger)
-- ============================================================
-- Signed deltas for on-hand and reserved, plus balances after each move.
-- actor_type: OPERATOR (p_actor supplied), ROBOT, or SYSTEM.
-- ============================================================

CREATE TABLE public.inventory_movements (
    movement_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    inventory_id    UUID NOT NULL REFERENCES public.inventory(inventory_id) ON DELETE RESTRICT,
    movement_type   VARCHAR(30) NOT NULL CHECK (movement_type IN (
                        'STOCK_IN', 'RESTOCKED', 'RETURNED',
                        'RESERVED', 'RELEASED', 'PICKED_BY_ROBOT',
                        'ADJUSTMENT', 'EXPIRED', 'DAMAGED')),
    on_hand_delta   INTEGER NOT NULL,
    reserved_delta  INTEGER NOT NULL,
    on_hand_after   INTEGER NOT NULL CHECK (on_hand_after >= 0),
    reserved_after  INTEGER NOT NULL CHECK (reserved_after >= 0),

    actor_type      VARCHAR(10) NOT NULL CHECK (actor_type IN ('OPERATOR', 'ROBOT', 'SYSTEM')),
    actor           TEXT,

    reservation_id  UUID REFERENCES public.reservations(reservation_id) ON DELETE RESTRICT,
    task_id         UUID REFERENCES public.robot_tasks(task_id) ON DELETE RESTRICT,
    task_item_id    UUID REFERENCES public.robot_task_items(task_item_id) ON DELETE RESTRICT,
    prescription_id UUID REFERENCES public.prescriptions(prescription_id) ON DELETE RESTRICT,

    reason          TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT movement_operator_has_actor
        CHECK (actor_type <> 'OPERATOR' OR actor IS NOT NULL),
    CONSTRAINT movement_reservation_link
        CHECK (movement_type NOT IN ('RESERVED', 'RELEASED', 'PICKED_BY_ROBOT')
               OR reservation_id IS NOT NULL),
    CONSTRAINT movement_shape CHECK (
        (movement_type IN ('STOCK_IN', 'RESTOCKED', 'RETURNED')
            AND on_hand_delta > 0 AND reserved_delta = 0)
        OR (movement_type = 'RESERVED'
            AND on_hand_delta = 0 AND reserved_delta > 0)
        OR (movement_type = 'RELEASED'
            AND on_hand_delta = 0 AND reserved_delta < 0)
        OR (movement_type = 'PICKED_BY_ROBOT'
            AND on_hand_delta < 0 AND reserved_delta < 0)
        OR (movement_type IN ('EXPIRED', 'DAMAGED')
            AND on_hand_delta < 0 AND reserved_delta = 0 AND reason IS NOT NULL)
        OR (movement_type = 'ADJUSTMENT'
            AND on_hand_delta <> 0 AND reserved_delta = 0 AND reason IS NOT NULL)
    )
);

CREATE INDEX inventory_movements_inventory_idx ON public.inventory_movements(inventory_id);
CREATE INDEX inventory_movements_task_idx ON public.inventory_movements(task_id);
CREATE INDEX inventory_movements_task_item_idx ON public.inventory_movements(task_item_id);
CREATE INDEX inventory_movements_prescription_idx ON public.inventory_movements(prescription_id);
CREATE INDEX inventory_movements_created_at_idx ON public.inventory_movements(created_at);


-- ============================================================
-- 9. AUDIT LOG (append-only, operator actions)
-- ============================================================

CREATE TABLE public.audit_log (
    audit_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor        TEXT NOT NULL,
    action       VARCHAR(100) NOT NULL,
    entity_type  VARCHAR(50) NOT NULL,
    entity_id    UUID,
    details      JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX audit_log_entity_idx ON public.audit_log(entity_type, entity_id);
CREATE INDEX audit_log_actor_idx ON public.audit_log(actor);


-- ============================================================
-- 10. TRIGGER FUNCTIONS
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.forbid_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_task_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    IF NOT (
        (OLD.status = 'QUEUED'      AND NEW.status IN ('ASSIGNED', 'CANCELLED'))
        OR (OLD.status = 'ASSIGNED'    AND NEW.status IN ('IN_PROGRESS', 'FAILED', 'CANCELLED'))
        OR (OLD.status = 'IN_PROGRESS' AND NEW.status IN ('COMPLETED', 'FAILED'))
    ) THEN
        RAISE EXCEPTION 'Illegal task transition % -> %', OLD.status, NEW.status;
    END IF;

    RETURN NEW;
END;
$$;

-- Runs when a task ends: releases reservations, cancels unpicked items,
-- returns prescription items to PENDING, and frees the robot.
CREATE OR REPLACE FUNCTION public.on_robot_task_terminal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_res       RECORD;
    v_on_hand   INTEGER;
    v_reserved  INTEGER;
BEGIN
    IF NEW.status IN ('FAILED', 'CANCELLED') THEN

        FOR v_res IN
            SELECT res.reservation_id, res.inventory_id, res.quantity, res.task_item_id
              FROM public.reservations res
              JOIN public.robot_task_items rti ON rti.task_item_id = res.task_item_id
             WHERE rti.task_id = NEW.task_id
               AND res.status = 'ACTIVE'
             ORDER BY res.inventory_id
             FOR UPDATE OF res
        LOOP
            UPDATE public.inventory
               SET reserved_quantity = reserved_quantity - v_res.quantity,
                   updated_at = NOW()
             WHERE inventory_id = v_res.inventory_id
            RETURNING quantity, reserved_quantity INTO v_on_hand, v_reserved;

            UPDATE public.reservations
               SET status = 'RELEASED', resolved_at = NOW()
             WHERE reservation_id = v_res.reservation_id;

            INSERT INTO public.inventory_movements (
                inventory_id, movement_type, on_hand_delta, reserved_delta,
                on_hand_after, reserved_after, actor_type,
                reservation_id, task_id, task_item_id, reason)
            VALUES (
                v_res.inventory_id, 'RELEASED', 0, -v_res.quantity,
                v_on_hand, v_reserved, 'SYSTEM',
                v_res.reservation_id, NEW.task_id, v_res.task_item_id,
                'Task ' || NEW.status);
        END LOOP;

        UPDATE public.robot_task_items
           SET status = 'CANCELLED', updated_at = NOW()
         WHERE task_id = NEW.task_id
           AND status = 'RESERVED';

        UPDATE public.prescription_items pi
           SET status = 'PENDING', updated_at = NOW()
         WHERE pi.status = 'RESERVED'
           AND pi.prescription_item_id IN (
                SELECT rti.prescription_item_id
                  FROM public.robot_task_items rti
                 WHERE rti.task_id = NEW.task_id
                   AND rti.prescription_item_id IS NOT NULL)
           AND NOT EXISTS (
                SELECT 1 FROM public.robot_task_items x
                 WHERE x.prescription_item_id = pi.prescription_item_id
                   AND x.status = 'RESERVED');
    END IF;

    UPDATE public.robot
       SET active_task_id = NULL,
           status = CASE WHEN status = 'BUSY' THEN 'IDLE' ELSE status END,
           updated_at = NOW()
     WHERE active_task_id = NEW.task_id;

    RETURN NULL;
END;
$$;

-- Prescription becomes READY when every non-cancelled item is PICKED.
CREATE OR REPLACE FUNCTION public.recompute_prescription_status(p_prescription_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    UPDATE public.prescriptions
       SET status = 'READY', updated_at = NOW()
     WHERE prescription_id = p_prescription_id
       AND status IN ('PENDING', 'PROCESSING')
       AND EXISTS (
            SELECT 1 FROM public.prescription_items pi
             WHERE pi.prescription_id = p_prescription_id
               AND pi.status <> 'CANCELLED')
       AND NOT EXISTS (
            SELECT 1 FROM public.prescription_items pi
             WHERE pi.prescription_id = p_prescription_id
               AND pi.status NOT IN ('PICKED', 'CANCELLED'));
END;
$$;


-- ============================================================
-- 11. TRIGGERS
-- ============================================================

CREATE TRIGGER medicines_updated_at BEFORE UPDATE ON public.medicines
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER racks_updated_at BEFORE UPDATE ON public.racks
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER shelves_updated_at BEFORE UPDATE ON public.shelves
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER inventory_updated_at BEFORE UPDATE ON public.inventory
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER prescriptions_updated_at BEFORE UPDATE ON public.prescriptions
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER prescription_items_updated_at BEFORE UPDATE ON public.prescription_items
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER robot_tasks_updated_at BEFORE UPDATE ON public.robot_tasks
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER robot_updated_at BEFORE UPDATE ON public.robot
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER robot_task_items_updated_at BEFORE UPDATE ON public.robot_task_items
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER robot_tasks_transition
    BEFORE UPDATE OF status ON public.robot_tasks
    FOR EACH ROW EXECUTE FUNCTION public.check_task_transition();

CREATE TRIGGER robot_tasks_terminal
    AFTER UPDATE OF status ON public.robot_tasks
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status
          AND NEW.status IN ('COMPLETED', 'FAILED', 'CANCELLED'))
    EXECUTE FUNCTION public.on_robot_task_terminal();

CREATE TRIGGER inventory_movements_append_only
    BEFORE UPDATE OR DELETE ON public.inventory_movements
    FOR EACH ROW EXECUTE FUNCTION public.forbid_mutation();

CREATE TRIGGER audit_log_append_only
    BEFORE UPDATE OR DELETE ON public.audit_log
    FOR EACH ROW EXECUTE FUNCTION public.forbid_mutation();


-- ============================================================
-- 12. OPERATOR FUNCTIONS (service_role only)
-- ============================================================
-- Every function takes p_actor: the backend's name for whoever is acting.
-- It is recorded, not authenticated, by the database. Trust the backend.
-- ============================================================

CREATE OR REPLACE FUNCTION public.require_actor(p_actor TEXT)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
BEGIN
    IF p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION 'An actor name is required';
    END IF;
END;
$$;

-- 12a. Register a prescription
CREATE OR REPLACE FUNCTION public.register_prescription(
    p_actor           TEXT,
    p_rx_number       TEXT,
    p_prescriber_name TEXT,
    p_notes           TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_rx_id UUID;
BEGIN
    PERFORM public.require_actor(p_actor);

    IF p_rx_number IS NULL OR btrim(p_rx_number) = '' THEN
        RAISE EXCEPTION 'Prescription number is required';
    END IF;

    INSERT INTO public.prescriptions (rx_number, prescriber_name, notes, received_by)
    VALUES (btrim(p_rx_number), p_prescriber_name, p_notes, btrim(p_actor))
    RETURNING prescription_id INTO v_rx_id;

    INSERT INTO public.audit_log (actor, action, entity_type, entity_id)
    VALUES (btrim(p_actor), 'REGISTER_PRESCRIPTION', 'prescription', v_rx_id);

    RETURN v_rx_id;
END;
$$;

-- 12b. Add an item to a PENDING prescription
CREATE OR REPLACE FUNCTION public.add_prescription_item(
    p_actor               TEXT,
    p_prescription_id     UUID,
    p_medicine_id         UUID,
    p_quantity            INTEGER,
    p_dosage_instructions TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_status  TEXT;
    v_item_id UUID;
BEGIN
    PERFORM public.require_actor(p_actor);

    SELECT p.status INTO v_status
      FROM public.prescriptions p
     WHERE p.prescription_id = p_prescription_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Prescription not found';
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Cannot add items to a prescription that is %', v_status;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.medicines m
                    WHERE m.medicine_id = p_medicine_id AND m.is_active) THEN
        RAISE EXCEPTION 'Medicine not found or inactive';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    INSERT INTO public.prescription_items (prescription_id, medicine_id, quantity_required, dosage_instructions)
    VALUES (p_prescription_id, p_medicine_id, p_quantity, p_dosage_instructions)
    RETURNING prescription_item_id INTO v_item_id;

    RETURN v_item_id;
END;
$$;

-- 12c. Receive stock into a bin
CREATE OR REPLACE FUNCTION public.receive_stock(
    p_actor               TEXT,
    p_medicine_id         UUID,
    p_shelf_id            UUID,
    p_bin_code            TEXT,
    p_batch_number        TEXT,
    p_expiry_date         DATE,
    p_quantity            INTEGER,
    p_low_stock_threshold INTEGER DEFAULT 5
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_inv_id   UUID;
    v_med      UUID;
    v_batch    TEXT;
    v_expiry   DATE;
    v_qty      INTEGER;
    v_reserved INTEGER;
BEGIN
    PERFORM public.require_actor(p_actor);

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;
    IF p_expiry_date IS NOT NULL AND p_expiry_date < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot receive expired stock';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.medicines m
                    WHERE m.medicine_id = p_medicine_id AND m.is_active) THEN
        RAISE EXCEPTION 'Medicine not found or inactive';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.shelves s
                     JOIN public.racks r ON r.rack_id = s.rack_id
                    WHERE s.shelf_id = p_shelf_id AND s.is_active AND r.is_active) THEN
        RAISE EXCEPTION 'Shelf not found or inactive';
    END IF;

    SELECT i.inventory_id, i.medicine_id, i.batch_number, i.expiry_date,
           i.quantity, i.reserved_quantity
      INTO v_inv_id, v_med, v_batch, v_expiry, v_qty, v_reserved
      FROM public.inventory i
     WHERE i.shelf_id = p_shelf_id
       AND i.bin_code = p_bin_code
     FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO public.inventory (
            medicine_id, shelf_id, bin_code, batch_number, quantity,
            reserved_quantity, low_stock_threshold, expiry_date)
        VALUES (
            p_medicine_id, p_shelf_id, p_bin_code, p_batch_number, p_quantity,
            0, COALESCE(p_low_stock_threshold, 5), p_expiry_date)
        RETURNING inventory_id, quantity, reserved_quantity
             INTO v_inv_id, v_qty, v_reserved;

    ELSIF v_qty = 0 AND v_reserved = 0 THEN
        -- empty bin: accepts a new batch
        UPDATE public.inventory
           SET medicine_id = p_medicine_id,
               batch_number = p_batch_number,
               expiry_date = p_expiry_date,
               quantity = p_quantity,
               is_blocked = FALSE,
               block_reason = NULL,
               updated_at = NOW()
         WHERE inventory_id = v_inv_id
        RETURNING quantity, reserved_quantity INTO v_qty, v_reserved;

    ELSIF v_med <> p_medicine_id
          OR v_batch <> p_batch_number
          OR v_expiry IS DISTINCT FROM p_expiry_date THEN
        RAISE EXCEPTION 'Bin % on this shelf already holds a different batch', p_bin_code;

    ELSE
        UPDATE public.inventory
           SET quantity = quantity + p_quantity,
               updated_at = NOW()
         WHERE inventory_id = v_inv_id
        RETURNING quantity, reserved_quantity INTO v_qty, v_reserved;
    END IF;

    INSERT INTO public.inventory_movements (
        inventory_id, movement_type, on_hand_delta, reserved_delta,
        on_hand_after, reserved_after, actor_type, actor, reason)
    VALUES (
        v_inv_id, 'STOCK_IN', p_quantity, 0,
        v_qty, v_reserved, 'OPERATOR', btrim(p_actor),
        'Received batch ' || p_batch_number);

    INSERT INTO public.audit_log (actor, action, entity_type, entity_id, details)
    VALUES (btrim(p_actor), 'RECEIVE_STOCK', 'inventory', v_inv_id,
            jsonb_build_object('quantity', p_quantity, 'batch', p_batch_number));

    RETURN v_inv_id;
END;
$$;

-- 12d. Manual adjustment or write-off. Never drops below reserved quantity.
CREATE OR REPLACE FUNCTION public.adjust_stock(
    p_actor          TEXT,
    p_inventory_id   UUID,
    p_movement_type  TEXT,
    p_quantity       INTEGER,
    p_reason         TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_qty      INTEGER;
    v_reserved INTEGER;
    v_delta    INTEGER;
    v_new_qty  INTEGER;
BEGIN
    PERFORM public.require_actor(p_actor);

    IF p_movement_type NOT IN ('ADJUSTMENT', 'DAMAGED', 'EXPIRED') THEN
        RAISE EXCEPTION 'Unsupported adjustment type %', p_movement_type;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'A reason is required';
    END IF;
    IF p_quantity IS NULL OR p_quantity = 0 THEN
        RAISE EXCEPTION 'Quantity must be non-zero';
    END IF;

    IF p_movement_type = 'ADJUSTMENT' THEN
        v_delta := p_quantity;
    ELSE
        IF p_quantity < 0 THEN
            RAISE EXCEPTION 'Write-off quantity must be positive';
        END IF;
        v_delta := -p_quantity;
    END IF;

    SELECT i.quantity, i.reserved_quantity INTO v_qty, v_reserved
      FROM public.inventory i
     WHERE i.inventory_id = p_inventory_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory row not found';
    END IF;

    v_new_qty := v_qty + v_delta;
    IF v_new_qty < v_reserved THEN
        RAISE EXCEPTION 'Adjustment would drop stock below reserved quantity (%)', v_reserved;
    END IF;

    UPDATE public.inventory
       SET quantity = v_new_qty, updated_at = NOW()
     WHERE inventory_id = p_inventory_id;

    INSERT INTO public.inventory_movements (
        inventory_id, movement_type, on_hand_delta, reserved_delta,
        on_hand_after, reserved_after, actor_type, actor, reason)
    VALUES (
        p_inventory_id, p_movement_type, v_delta, 0,
        v_new_qty, v_reserved, 'OPERATOR', btrim(p_actor), p_reason);

    INSERT INTO public.audit_log (actor, action, entity_type, entity_id, details)
    VALUES (btrim(p_actor), p_movement_type, 'inventory', p_inventory_id,
            jsonb_build_object('delta', v_delta, 'reason', p_reason));
END;
$$;

-- 12e. Block or unblock a bin. Does not cancel existing reservations.
CREATE OR REPLACE FUNCTION public.block_inventory(
    p_actor        TEXT,
    p_inventory_id UUID,
    p_blocked      BOOLEAN,
    p_reason       TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    PERFORM public.require_actor(p_actor);

    IF p_blocked AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
        RAISE EXCEPTION 'A reason is required to block stock';
    END IF;

    UPDATE public.inventory
       SET is_blocked = p_blocked,
           block_reason = CASE WHEN p_blocked THEN p_reason ELSE NULL END,
           updated_at = NOW()
     WHERE inventory_id = p_inventory_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Inventory row not found';
    END IF;

    INSERT INTO public.audit_log (actor, action, entity_type, entity_id, details)
    VALUES (btrim(p_actor),
            CASE WHEN p_blocked THEN 'BLOCK_INVENTORY' ELSE 'UNBLOCK_INVENTORY' END,
            'inventory', p_inventory_id, jsonb_build_object('reason', p_reason));
END;
$$;

-- 12f. Pharmacist verification. Required before any picking.
CREATE OR REPLACE FUNCTION public.verify_prescription(
    p_actor           TEXT,
    p_prescription_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_status      TEXT;
    v_verified_at TIMESTAMPTZ;
BEGIN
    PERFORM public.require_actor(p_actor);

    SELECT p.status, p.verified_at INTO v_status, v_verified_at
      FROM public.prescriptions p
     WHERE p.prescription_id = p_prescription_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Prescription not found';
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Prescription is %, cannot verify', v_status;
    END IF;
    IF v_verified_at IS NOT NULL THEN
        RAISE EXCEPTION 'Prescription is already verified';
    END IF;

    UPDATE public.prescriptions
       SET verified_by = btrim(p_actor), verified_at = NOW()
     WHERE prescription_id = p_prescription_id;

    INSERT INTO public.audit_log (actor, action, entity_type, entity_id)
    VALUES (btrim(p_actor), 'VERIFY_PRESCRIPTION', 'prescription', p_prescription_id);
END;
$$;

-- 12g. Plan a pick: allocate bins FEFO, reserve stock, create the task.
-- Items short on stock become UNAVAILABLE. Items are never partially reserved.
CREATE OR REPLACE FUNCTION public.plan_prescription_pick(
    p_actor               TEXT,
    p_prescription_id     UUID,
    p_priority            INTEGER DEFAULT 5,
    p_reservation_minutes INTEGER DEFAULT 30
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_status       TEXT;
    v_verified_at  TIMESTAMPTZ;
    v_task_id      UUID;
    v_item         RECORD;
    v_inv          RECORD;
    v_need         INTEGER;
    v_remaining    INTEGER;
    v_take         INTEGER;
    v_available    INTEGER;
    v_task_item_id UUID;
    v_res_id       UUID;
    v_planned_bins INTEGER := 0;
BEGIN
    PERFORM public.require_actor(p_actor);

    SELECT p.status, p.verified_at INTO v_status, v_verified_at
      FROM public.prescriptions p
     WHERE p.prescription_id = p_prescription_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Prescription not found';
    END IF;
    IF v_status NOT IN ('PENDING', 'PROCESSING') THEN
        RAISE EXCEPTION 'Prescription is %, cannot plan a pick', v_status;
    END IF;
    IF v_verified_at IS NULL THEN
        RAISE EXCEPTION 'Prescription must be verified before picking';
    END IF;
    IF EXISTS (SELECT 1 FROM public.robot_tasks t
                WHERE t.prescription_id = p_prescription_id
                  AND t.status IN ('QUEUED', 'ASSIGNED', 'IN_PROGRESS')) THEN
        RAISE EXCEPTION 'An active pick task already exists for this prescription';
    END IF;

    INSERT INTO public.robot_tasks (prescription_id, task_type, priority, status)
    VALUES (p_prescription_id, 'PICK_MEDICINE', p_priority, 'QUEUED')
    RETURNING task_id INTO v_task_id;

    FOR v_item IN
        SELECT pi.prescription_item_id, pi.medicine_id, pi.quantity_required,
               m.name, m.is_active
          FROM public.prescription_items pi
          JOIN public.medicines m ON m.medicine_id = pi.medicine_id
         WHERE pi.prescription_id = p_prescription_id
           AND pi.status IN ('PENDING', 'UNAVAILABLE')
         ORDER BY pi.created_at
    LOOP
        IF NOT v_item.is_active THEN
            RAISE EXCEPTION 'Medicine "%" is inactive', v_item.name;
        END IF;

        -- still owed (an earlier failed task may have picked part of it)
        SELECT v_item.quantity_required - COALESCE(SUM(rti.quantity_picked), 0)
          INTO v_need
          FROM public.robot_task_items rti
         WHERE rti.prescription_item_id = v_item.prescription_item_id;

        IF v_need <= 0 THEN
            UPDATE public.prescription_items
               SET status = 'PICKED', updated_at = NOW()
             WHERE prescription_item_id = v_item.prescription_item_id;
            CONTINUE;
        END IF;

        SELECT COALESCE(SUM(i.quantity - i.reserved_quantity), 0) INTO v_available
          FROM public.inventory i
          JOIN public.shelves s ON s.shelf_id = i.shelf_id
          JOIN public.racks r ON r.rack_id = s.rack_id
         WHERE i.medicine_id = v_item.medicine_id
           AND NOT i.is_blocked
           AND (i.expiry_date IS NULL OR i.expiry_date >= CURRENT_DATE)
           AND s.is_active AND r.is_active;

        IF v_available < v_need THEN
            UPDATE public.prescription_items
               SET status = 'UNAVAILABLE', updated_at = NOW()
             WHERE prescription_item_id = v_item.prescription_item_id;
            CONTINUE;
        END IF;

        v_remaining := v_need;

        FOR v_inv IN
            SELECT i.inventory_id, i.medicine_id, i.quantity, i.reserved_quantity, i.bin_code,
                   s.shelf_id, s.shelf_number, s.height_cm,
                   r.rack_id, r.rack_number,
                   r.x_coordinate, r.y_coordinate, r.orientation_degrees
              FROM public.inventory i
              JOIN public.shelves s ON s.shelf_id = i.shelf_id
              JOIN public.racks r ON r.rack_id = s.rack_id
             WHERE i.medicine_id = v_item.medicine_id
               AND NOT i.is_blocked
               AND (i.expiry_date IS NULL OR i.expiry_date >= CURRENT_DATE)
               AND i.quantity > i.reserved_quantity
               AND s.is_active AND r.is_active
             ORDER BY (i.expiry_date IS NULL), i.expiry_date, i.created_at, i.inventory_id
             FOR UPDATE OF i
        LOOP
            EXIT WHEN v_remaining <= 0;

            v_take := LEAST(v_remaining, v_inv.quantity - v_inv.reserved_quantity);

            INSERT INTO public.robot_task_items (
                task_id, prescription_item_id, medicine_id, inventory_id, quantity_requested,
                status, rack_id, shelf_id, rack_number, shelf_number, bin_code,
                target_x, target_y, target_height_cm, target_orientation_degrees)
            VALUES (
                v_task_id, v_item.prescription_item_id, v_inv.medicine_id, v_inv.inventory_id, v_take,
                'RESERVED', v_inv.rack_id, v_inv.shelf_id, v_inv.rack_number, v_inv.shelf_number,
                v_inv.bin_code, v_inv.x_coordinate, v_inv.y_coordinate, v_inv.height_cm,
                v_inv.orientation_degrees)
            RETURNING task_item_id INTO v_task_item_id;

            INSERT INTO public.reservations (task_item_id, inventory_id, quantity, expires_at)
            VALUES (v_task_item_id, v_inv.inventory_id, v_take,
                    NOW() + make_interval(mins => p_reservation_minutes))
            RETURNING reservation_id INTO v_res_id;

            UPDATE public.inventory
               SET reserved_quantity = reserved_quantity + v_take,
                   updated_at = NOW()
             WHERE inventory_id = v_inv.inventory_id;

            INSERT INTO public.inventory_movements (
                inventory_id, movement_type, on_hand_delta, reserved_delta,
                on_hand_after, reserved_after, actor_type, actor,
                reservation_id, task_id, task_item_id, prescription_id)
            VALUES (
                v_inv.inventory_id, 'RESERVED', 0, v_take,
                v_inv.quantity, v_inv.reserved_quantity + v_take, 'OPERATOR', btrim(p_actor),
                v_res_id, v_task_id, v_task_item_id, p_prescription_id);

            v_remaining := v_remaining - v_take;
            v_planned_bins := v_planned_bins + 1;
        END LOOP;

        IF v_remaining > 0 THEN
            -- stock moved between pre-check and lock: fail the whole plan
            RAISE EXCEPTION 'Stock for "%" changed during planning; retry', v_item.name;
        END IF;

        UPDATE public.prescription_items
           SET status = 'RESERVED', updated_at = NOW()
         WHERE prescription_item_id = v_item.prescription_item_id;
    END LOOP;

    IF v_planned_bins = 0 THEN
        UPDATE public.robot_tasks
           SET status = 'CANCELLED', error_message = 'No allocatable items'
         WHERE task_id = v_task_id;
        RETURN NULL;
    END IF;

    UPDATE public.prescriptions
       SET status = 'PROCESSING', updated_at = NOW()
     WHERE prescription_id = p_prescription_id;

    INSERT INTO public.audit_log (actor, action, entity_type, entity_id, details)
    VALUES (btrim(p_actor), 'PLAN_PICK', 'robot_task', v_task_id,
            jsonb_build_object('prescription_id', p_prescription_id));

    RETURN v_task_id;
END;
$$;

-- 12h. Cancel a prescription. Refused while the robot is working on it,
-- or after items are picked (return-to-stock is not modelled yet).
CREATE OR REPLACE FUNCTION public.cancel_prescription(
    p_actor           TEXT,
    p_prescription_id UUID,
    p_reason          TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_status TEXT;
BEGIN
    PERFORM public.require_actor(p_actor);

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'A cancellation reason is required';
    END IF;

    SELECT p.status INTO v_status
      FROM public.prescriptions p
     WHERE p.prescription_id = p_prescription_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Prescription not found';
    END IF;
    IF v_status IN ('COMPLETED', 'CANCELLED') THEN
        RAISE EXCEPTION 'Prescription is %, cannot cancel', v_status;
    END IF;

    IF EXISTS (SELECT 1 FROM public.robot_tasks t
                WHERE t.prescription_id = p_prescription_id
                  AND t.status = 'IN_PROGRESS') THEN
        RAISE EXCEPTION 'Robot is executing this prescription; wait for it to finish or fail';
    END IF;

    IF EXISTS (SELECT 1 FROM public.robot_task_items rti
                 JOIN public.robot_tasks t ON t.task_id = rti.task_id
                WHERE t.prescription_id = p_prescription_id
                  AND rti.status = 'PICKED') THEN
        RAISE EXCEPTION 'Items already picked; return them to stock before cancelling';
    END IF;

    -- trigger releases reservations for these tasks
    UPDATE public.robot_tasks
       SET status = 'CANCELLED',
           error_message = 'Prescription cancelled: ' || p_reason
     WHERE prescription_id = p_prescription_id
       AND status IN ('QUEUED', 'ASSIGNED');

    UPDATE public.prescription_items
       SET status = 'CANCELLED', updated_at = NOW()
     WHERE prescription_id = p_prescription_id
       AND status <> 'PICKED';

    UPDATE public.prescriptions
       SET status = 'CANCELLED',
           cancelled_by = btrim(p_actor),
           cancelled_at = NOW(),
           cancel_reason = p_reason
     WHERE prescription_id = p_prescription_id;

    INSERT INTO public.audit_log (actor, action, entity_type, entity_id, details)
    VALUES (btrim(p_actor), 'CANCEL_PRESCRIPTION', 'prescription', p_prescription_id,
            jsonb_build_object('reason', p_reason));
END;
$$;

-- 12i. Final dispense. Requires READY (all items picked).
-- Verifier and dispenser are recorded; enforcing that they differ is an
-- option (see notes), not done here.
CREATE OR REPLACE FUNCTION public.dispense_prescription(
    p_actor           TEXT,
    p_prescription_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_status TEXT;
BEGIN
    PERFORM public.require_actor(p_actor);

    SELECT p.status INTO v_status
      FROM public.prescriptions p
     WHERE p.prescription_id = p_prescription_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Prescription not found';
    END IF;
    IF v_status <> 'READY' THEN
        RAISE EXCEPTION 'Prescription is %, not READY', v_status;
    END IF;
    IF EXISTS (SELECT 1 FROM public.prescription_items pi
                WHERE pi.prescription_id = p_prescription_id
                  AND pi.status NOT IN ('PICKED', 'CANCELLED')) THEN
        RAISE EXCEPTION 'Not all items are picked';
    END IF;

    UPDATE public.prescriptions
       SET status = 'COMPLETED',
           dispensed_by = btrim(p_actor),
           dispensed_at = NOW()
     WHERE prescription_id = p_prescription_id;

    INSERT INTO public.audit_log (actor, action, entity_type, entity_id)
    VALUES (btrim(p_actor), 'DISPENSE_PRESCRIPTION', 'prescription', p_prescription_id);
END;
$$;


-- ============================================================
-- 13. ROBOT FUNCTIONS (service_role only)
-- ============================================================

-- 13a. Heartbeat. BUSY is set only by claim.
CREATE OR REPLACE FUNCTION public.robot_heartbeat(
    p_status  TEXT,
    p_x       NUMERIC,
    p_y       NUMERIC,
    p_z       NUMERIC,
    p_battery NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF p_status NOT IN ('IDLE', 'CHARGING', 'ERROR', 'OFFLINE', 'MAINTENANCE') THEN
        RAISE EXCEPTION 'Robot cannot report status % (BUSY is set by task claim)', p_status;
    END IF;

    UPDATE public.robot
       SET status = p_status,
           current_x = p_x,
           current_y = p_y,
           current_z = p_z,
           battery_percent = p_battery,
           last_seen_at = NOW()
     WHERE robot_id = 1;
END;
$$;

-- 13b. Claim the next queued task. NULL if robot not IDLE or queue empty.
CREATE OR REPLACE FUNCTION public.robot_claim_next_task()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_robot_status TEXT;
    v_task_id      UUID;
BEGIN
    SELECT r.status INTO v_robot_status
      FROM public.robot r
     WHERE r.robot_id = 1
     FOR UPDATE;

    IF v_robot_status <> 'IDLE' THEN
        RETURN NULL;
    END IF;

    SELECT t.task_id INTO v_task_id
      FROM public.robot_tasks t
     WHERE t.status = 'QUEUED'
     ORDER BY t.priority DESC, t.created_at
     FOR UPDATE SKIP LOCKED
     LIMIT 1;

    IF v_task_id IS NULL THEN
        RETURN NULL;
    END IF;

    UPDATE public.robot_tasks
       SET status = 'ASSIGNED', assigned_at = NOW()
     WHERE task_id = v_task_id;

    UPDATE public.robot
       SET status = 'BUSY', active_task_id = v_task_id
     WHERE robot_id = 1;

    RETURN v_task_id;
END;
$$;

-- 13c. Robot starts its assigned task.
CREATE OR REPLACE FUNCTION public.robot_start_task(
    p_task_id UUID,
    p_x       NUMERIC,
    p_y       NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    PERFORM 1 FROM public.robot r
     WHERE r.robot_id = 1 AND r.active_task_id = p_task_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Task % is not the robot''s active task', p_task_id;
    END IF;

    UPDATE public.robot_tasks
       SET status = 'IN_PROGRESS', started_at = NOW(), start_x = p_x, start_y = p_y
     WHERE task_id = p_task_id
       AND status = 'ASSIGNED';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Task % is not ASSIGNED', p_task_id;
    END IF;

    UPDATE public.robot
       SET current_x = p_x, current_y = p_y
     WHERE robot_id = 1;
END;
$$;

-- 13d. Robot picked a bin. All-or-nothing per task item: the full reserved
-- quantity, or report failure with robot_fail_task.
CREATE OR REPLACE FUNCTION public.robot_pick(p_task_item_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_task_id         UUID;
    v_prescription_id UUID;
    v_pi_id           UUID;
    v_inv_id          UUID;
    v_qty             INTEGER;
    v_item_status     TEXT;
    v_res_id          UUID;
    v_res_status      TEXT;
    v_on_hand         INTEGER;
    v_reserved        INTEGER;
    v_is_active       BOOLEAN;
BEGIN
    SELECT rti.task_id, rti.prescription_item_id, rti.inventory_id,
           rti.quantity_requested, rti.status
      INTO v_task_id, v_pi_id, v_inv_id, v_qty, v_item_status
      FROM public.robot_task_items rti
     WHERE rti.task_item_id = p_task_item_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Task item not found';
    END IF;
    IF v_item_status <> 'RESERVED' THEN
        RAISE EXCEPTION 'Task item is %, not RESERVED', v_item_status;
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.robot r
          JOIN public.robot_tasks t ON t.task_id = r.active_task_id
         WHERE r.robot_id = 1
           AND t.task_id = v_task_id
           AND t.status = 'IN_PROGRESS')
      INTO v_is_active;
    IF NOT v_is_active THEN
        RAISE EXCEPTION 'Task % is not the robot''s active in-progress task', v_task_id;
    END IF;

    SELECT t.prescription_id INTO v_prescription_id
      FROM public.robot_tasks t
     WHERE t.task_id = v_task_id;

    SELECT res.reservation_id, res.status INTO v_res_id, v_res_status
      FROM public.reservations res
     WHERE res.task_item_id = p_task_item_id
     FOR UPDATE;
    IF NOT FOUND OR v_res_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'No active reservation for this task item';
    END IF;

    SELECT i.quantity, i.reserved_quantity INTO v_on_hand, v_reserved
      FROM public.inventory i
     WHERE i.inventory_id = v_inv_id
     FOR UPDATE;
    IF v_on_hand < v_qty OR v_reserved < v_qty THEN
        RAISE EXCEPTION 'Inventory invariant violated for inventory %', v_inv_id;
    END IF;

    v_on_hand := v_on_hand - v_qty;
    v_reserved := v_reserved - v_qty;

    UPDATE public.inventory
       SET quantity = v_on_hand, reserved_quantity = v_reserved, updated_at = NOW()
     WHERE inventory_id = v_inv_id;

    UPDATE public.reservations
       SET status = 'CONSUMED', resolved_at = NOW()
     WHERE reservation_id = v_res_id;

    UPDATE public.robot_task_items
       SET status = 'PICKED', quantity_picked = v_qty, picked_at = NOW()
     WHERE task_item_id = p_task_item_id;

    INSERT INTO public.inventory_movements (
        inventory_id, movement_type, on_hand_delta, reserved_delta,
        on_hand_after, reserved_after, actor_type,
        reservation_id, task_id, task_item_id, prescription_id)
    VALUES (
        v_inv_id, 'PICKED_BY_ROBOT', -v_qty, -v_qty,
        v_on_hand, v_reserved, 'ROBOT',
        v_res_id, v_task_id, p_task_item_id, v_prescription_id);

    IF v_pi_id IS NOT NULL THEN
        UPDATE public.prescription_items pi
           SET status = CASE
                   WHEN (SELECT COALESCE(SUM(x.quantity_picked), 0)
                           FROM public.robot_task_items x
                          WHERE x.prescription_item_id = pi.prescription_item_id)
                        >= pi.quantity_required
                   THEN 'PICKED' ELSE 'RESERVED' END,
               updated_at = NOW()
         WHERE pi.prescription_item_id = v_pi_id;
    END IF;

    IF v_prescription_id IS NOT NULL THEN
        PERFORM public.recompute_prescription_status(v_prescription_id);
    END IF;
END;
$$;

-- 13e. Robot finished all items.
CREATE OR REPLACE FUNCTION public.robot_complete_task(
    p_task_id UUID,
    p_x       NUMERIC,
    p_y       NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    PERFORM 1 FROM public.robot r
     WHERE r.robot_id = 1 AND r.active_task_id = p_task_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Task % is not the robot''s active task', p_task_id;
    END IF;

    IF EXISTS (SELECT 1 FROM public.robot_task_items
                WHERE task_id = p_task_id AND status = 'RESERVED') THEN
        RAISE EXCEPTION 'Cannot complete: some items are still reserved';
    END IF;

    UPDATE public.robot_tasks
       SET status = 'COMPLETED', completed_at = NOW(), end_x = p_x, end_y = p_y
     WHERE task_id = p_task_id
       AND status = 'IN_PROGRESS';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Task % is not IN_PROGRESS', p_task_id;
    END IF;
END;
$$;

-- 13f. Robot failed. The trigger releases reservations and frees the robot.
CREATE OR REPLACE FUNCTION public.robot_fail_task(
    p_task_id UUID,
    p_error   TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    UPDATE public.robot_tasks
       SET status = 'FAILED', error_message = p_error
     WHERE task_id = p_task_id
       AND status IN ('ASSIGNED', 'IN_PROGRESS');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Task % is not ASSIGNED or IN_PROGRESS', p_task_id;
    END IF;
END;
$$;

-- 13g. Expire reservations on tasks that never started. Run every minute (section 16).
CREATE OR REPLACE FUNCTION public.expire_stale_reservations()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_task  RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_task IN
        SELECT DISTINCT t.task_id, t.status
          FROM public.robot_tasks t
          JOIN public.robot_task_items rti ON rti.task_id = t.task_id
          JOIN public.reservations res ON res.task_item_id = rti.task_item_id
         WHERE res.status = 'ACTIVE'
           AND res.expires_at < NOW()
           AND t.status IN ('QUEUED', 'ASSIGNED')
    LOOP
        UPDATE public.robot_tasks
           SET status = CASE WHEN v_task.status = 'QUEUED' THEN 'CANCELLED' ELSE 'FAILED' END,
               error_message = 'Reservation expired before pick'
         WHERE task_id = v_task.task_id
           AND status = v_task.status;
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;


-- ============================================================
-- 14. VIEWS (for the backend's reads)
-- ============================================================

CREATE OR REPLACE VIEW public.inventory_status_view
WITH (security_invoker = true) AS
SELECT
    i.inventory_id,
    i.medicine_id,
    m.name AS medicine_name,
    m.generic_name,
    m.brand_name,
    m.strength,
    m.dosage_form,
    m.barcode,
    i.batch_number,
    i.quantity,
    i.reserved_quantity,
    (i.quantity - i.reserved_quantity) AS available_quantity,
    i.low_stock_threshold,
    i.expiry_date,
    i.is_blocked,
    i.block_reason,
    CASE
        WHEN i.is_blocked THEN 'BLOCKED'
        WHEN i.expiry_date IS NOT NULL AND i.expiry_date < CURRENT_DATE THEN 'EXPIRED'
        WHEN (i.quantity - i.reserved_quantity) <= 0 THEN 'OUT_OF_STOCK'
        WHEN (i.quantity - i.reserved_quantity) <= i.low_stock_threshold THEN 'LOW_STOCK'
        ELSE 'AVAILABLE'
    END AS stock_status,
    r.rack_id,
    r.rack_number,
    r.zone,
    s.shelf_id,
    s.shelf_number,
    s.height_cm AS shelf_height_cm,
    i.bin_code,
    r.x_coordinate,
    r.y_coordinate,
    r.orientation_degrees
FROM public.inventory i
JOIN public.medicines m ON m.medicine_id = i.medicine_id
JOIN public.shelves s ON s.shelf_id = i.shelf_id
JOIN public.racks r ON r.rack_id = s.rack_id;

CREATE OR REPLACE VIEW public.robot_task_location_view
WITH (security_invoker = true) AS
SELECT
    rti.task_item_id,
    rti.task_id,
    rti.medicine_id,
    m.name AS medicine_name,
    m.generic_name,
    m.brand_name,
    m.strength,
    m.dosage_form,
    rti.rack_id,
    rti.shelf_id,
    rti.rack_number,
    rti.shelf_number,
    rti.bin_code,
    rti.target_x,
    rti.target_y,
    rti.target_height_cm,
    rti.target_orientation_degrees,
    rti.quantity_requested,
    rti.quantity_picked,
    rti.status
FROM public.robot_task_items rti
JOIN public.medicines m ON m.medicine_id = rti.medicine_id;

CREATE OR REPLACE VIEW public.prescription_progress_view
WITH (security_invoker = true) AS
SELECT
    pi.prescription_item_id,
    pi.prescription_id,
    pi.medicine_id,
    pi.quantity_required,
    COALESCE(SUM(rti.quantity_picked), 0) AS quantity_picked,
    pi.status
FROM public.prescription_items pi
LEFT JOIN public.robot_task_items rti
       ON rti.prescription_item_id = pi.prescription_item_id
GROUP BY pi.prescription_item_id;


-- ============================================================
-- 15. ACCESS CONTROL
-- ============================================================
-- No direct access for anon or authenticated. RLS is on with no policies,
-- so anything that reaches a table without a grant is denied. service_role
-- bypasses RLS and is the only role the backend and robot use.
-- ============================================================

ALTER TABLE public.medicines           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.racks               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shelves             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prescriptions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prescription_items  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.robot_tasks         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.robot               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.robot_task_items    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reservations        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log           ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;

-- Internal helpers (triggers, recompute, require_actor) keep no grants.
-- Definer functions run as the owner and can call them.

-- Operator functions
GRANT EXECUTE ON FUNCTION public.register_prescription(TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.add_prescription_item(TEXT, UUID, UUID, INTEGER, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.receive_stock(TEXT, UUID, UUID, TEXT, TEXT, DATE, INTEGER, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.adjust_stock(TEXT, UUID, TEXT, INTEGER, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.block_inventory(TEXT, UUID, BOOLEAN, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.verify_prescription(TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.plan_prescription_pick(TEXT, UUID, INTEGER, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.cancel_prescription(TEXT, UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.dispense_prescription(TEXT, UUID) TO service_role;

-- Robot functions
GRANT EXECUTE ON FUNCTION public.robot_heartbeat(TEXT, NUMERIC, NUMERIC, NUMERIC, NUMERIC) TO service_role;
GRANT EXECUTE ON FUNCTION public.robot_claim_next_task() TO service_role;
GRANT EXECUTE ON FUNCTION public.robot_start_task(UUID, NUMERIC, NUMERIC) TO service_role;
GRANT EXECUTE ON FUNCTION public.robot_pick(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.robot_complete_task(UUID, NUMERIC, NUMERIC) TO service_role;
GRANT EXECUTE ON FUNCTION public.robot_fail_task(UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.expire_stale_reservations() TO service_role;

-- Reads: the backend uses service_role, so it sees everything through the
-- tables and views. Catalog writes (medicines, racks, shelves) are done by the
-- backend directly, since they are configuration rather than stock movements.


-- ============================================================
-- 16. SCHEDULED JOBS (optional, requires pg_cron)
-- ============================================================
-- SELECT cron.schedule(
--     'expire-stale-reservations',
--     '* * * * *',
--     $$SELECT public.expire_stale_reservations()$$
-- );
--
-- ============================================================
-- END OF SCHEMA
-- ============================================================