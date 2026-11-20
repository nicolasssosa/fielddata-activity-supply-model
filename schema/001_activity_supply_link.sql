-- ============================================================================
-- Tablas existentes
-- ============================================================================

SET lock_timeout = '5s';

ALTER TABLE structured_data
    ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
    ADD COLUMN IF NOT EXISTS deleted_by uuid;

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS uq_sd_tenant_key
    ON structured_data (establishment_id, id, type, record_date);
ALTER TABLE structured_data
    ADD CONSTRAINT uq_sd_tenant_key UNIQUE USING INDEX uq_sd_tenant_key;

CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_sd_feed
    ON structured_data (establishment_id, record_date DESC, id DESC)
    WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS uq_supply_tenant
    ON supply (establishment_id, id);
ALTER TABLE supply
    ADD CONSTRAINT uq_supply_tenant UNIQUE USING INDEX uq_supply_tenant;


-- ============================================================================
-- Tipos
-- ============================================================================

CREATE TYPE supply_link_role       AS ENUM ('APPLICATION', 'CONSUMPTION');
CREATE TYPE supply_link_origin     AS ENUM ('ACTIVITY', 'MANUAL', 'MIGRATION');
CREATE TYPE supply_quantity_source AS ENUM ('USER', 'DERIVED');


-- ============================================================================
-- activity_supply_link
-- ============================================================================

CREATE TABLE activity_supply_link (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    establishment_id    uuid NOT NULL,
    activity_id         uuid NOT NULL,
    activity_type       text NOT NULL,
    record_date         date NOT NULL,
    item_kind           text NOT NULL,
    item_id             uuid NOT NULL,
    position            smallint NOT NULL,
    role                supply_link_role NOT NULL,
    origin              supply_link_origin NOT NULL,

    supply_id           uuid,
    raw_name            text NOT NULL,

    dosage              numeric(14,4),
    dosage_units        text,
    quantity            numeric(14,4),
    quantity_unit_id    int REFERENCES units (id),
    quantity_source     supply_quantity_source,

    applied_by_link_id  uuid,
    parent_activity_id  uuid,

    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz,
    deleted_by          uuid,

    CONSTRAINT uq_link_parent_key UNIQUE (establishment_id, id, activity_id),

    CONSTRAINT fk_link_activity
        FOREIGN KEY (establishment_id, activity_id, activity_type, record_date)
        REFERENCES structured_data (establishment_id, id, type, record_date)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_link_supply
        FOREIGN KEY (establishment_id, supply_id)
        REFERENCES supply (establishment_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_link_applied_by
        FOREIGN KEY (establishment_id, applied_by_link_id, parent_activity_id)
        REFERENCES activity_supply_link (establishment_id, id, activity_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_link_parent_activity
        FOREIGN KEY (parent_activity_id)
        REFERENCES structured_data (id)
        ON DELETE RESTRICT,

    CONSTRAINT ck_activity_type CHECK (
        activity_type IN ('PLANTATION', 'FERTILIZATION', 'PULVERIZATION', 'TREATMENT', 'SUPPLYOUTPUT')
    ),
    CONSTRAINT ck_kind_by_type CHECK (
        CASE activity_type
            WHEN 'PLANTATION'    THEN item_kind IN ('FERTILIZER', 'GENETIC')
            WHEN 'FERTILIZATION' THEN item_kind = 'FERTILIZER'
            WHEN 'PULVERIZATION' THEN item_kind = 'TREATMENT'
            WHEN 'TREATMENT'     THEN item_kind = 'PRODUCT'
            WHEN 'SUPPLYOUTPUT'  THEN item_kind = 'RECORD'
        END
    ),
    CONSTRAINT ck_role_kind CHECK ((role = 'CONSUMPTION') = (item_kind = 'RECORD')),
    CONSTRAINT ck_application CHECK (
        role <> 'APPLICATION'
        OR (quantity IS NULL AND quantity_unit_id IS NULL AND quantity_source IS NULL)
    ),
    CONSTRAINT ck_consumption CHECK (
        role <> 'CONSUMPTION'
        OR (supply_id IS NOT NULL
            AND quantity IS NOT NULL AND quantity > 0
            AND quantity_unit_id IS NOT NULL
            AND quantity_source IS NOT NULL)
    ),
    CONSTRAINT ck_parent CHECK (
        (applied_by_link_id IS NULL) = (parent_activity_id IS NULL)
        AND (applied_by_link_id IS NULL OR role = 'CONSUMPTION')
        AND parent_activity_id IS DISTINCT FROM activity_id
    ),
    CONSTRAINT ck_origin CHECK (
        CASE origin
            WHEN 'MANUAL'    THEN role = 'CONSUMPTION' AND parent_activity_id IS NULL
            WHEN 'ACTIVITY'  THEN role = 'APPLICATION' OR parent_activity_id IS NOT NULL
            WHEN 'MIGRATION' THEN role = 'APPLICATION' OR parent_activity_id IS NOT NULL
        END
    ),
    CONSTRAINT ck_position CHECK (position >= 0 AND (item_kind <> 'GENETIC' OR position = 0)),
    CONSTRAINT ck_dosage CHECK (dosage IS NULL OR dosage >= 0),
    CONSTRAINT ck_raw_name CHECK (btrim(raw_name) <> ''),
    CONSTRAINT ck_deleted CHECK ((deleted_at IS NULL) = (deleted_by IS NULL))
);


-- ============================================================================
-- Índices
-- ============================================================================

CREATE UNIQUE INDEX uq_link_item_alive
    ON activity_supply_link (activity_id, item_id)
    WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX uq_link_one_consumption
    ON activity_supply_link (applied_by_link_id)
    WHERE applied_by_link_id IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX ix_link_activity
    ON activity_supply_link (activity_id);

CREATE INDEX ix_link_parent
    ON activity_supply_link (parent_activity_id)
    WHERE parent_activity_id IS NOT NULL;

CREATE INDEX ix_link_applied_by
    ON activity_supply_link (applied_by_link_id)
    WHERE applied_by_link_id IS NOT NULL;

CREATE INDEX ix_link_supply
    ON activity_supply_link (supply_id)
    WHERE supply_id IS NOT NULL;

CREATE INDEX ix_link_supply_date
    ON activity_supply_link (supply_id, record_date DESC)
    INCLUDE (role, quantity, quantity_unit_id, activity_id, parent_activity_id)
    WHERE supply_id IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX ix_link_derived_output
    ON activity_supply_link (activity_id)
    WHERE parent_activity_id IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX ix_link_unlinked
    ON activity_supply_link (establishment_id, lower(raw_name))
    WHERE supply_id IS NULL AND deleted_at IS NULL;


-- ============================================================================
-- Vistas
-- ============================================================================

CREATE VIEW v_supply_consumption AS
SELECT
    c.id                 AS consumption_link_id,
    c.establishment_id,
    c.record_date,
    c.supply_id,
    s.name               AS supply_name,
    c.quantity,
    u.label              AS unit_label,
    c.quantity_source,
    c.origin,
    c.activity_id        AS supply_output_id,
    c.parent_activity_id,
    a.dosage,
    a.dosage_units
FROM activity_supply_link c
JOIN supply s ON s.id = c.supply_id
JOIN units u ON u.id = c.quantity_unit_id
LEFT JOIN activity_supply_link a ON a.id = c.applied_by_link_id
WHERE c.role = 'CONSUMPTION'
  AND c.deleted_at IS NULL;
