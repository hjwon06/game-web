SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: stock_moves_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.stock_moves_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'stock_moves is append-only (% blocked)', TG_OP USING ERRCODE = 'restrict_violation';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: bom_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bom_lines (
    id bigint NOT NULL,
    product_id bigint NOT NULL,
    component_id bigint NOT NULL,
    qty_per numeric(14,3) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT bom_lines_not_self_check CHECK ((product_id <> component_id)),
    CONSTRAINT bom_lines_qty_per_check CHECK ((qty_per > (0)::numeric))
);


--
-- Name: bom_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bom_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bom_lines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bom_lines_id_seq OWNED BY public.bom_lines.id;


--
-- Name: commands; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commands (
    id bigint NOT NULL,
    idempotency_key uuid NOT NULL,
    machine_id bigint NOT NULL,
    kind character varying NOT NULL,
    base_version integer NOT NULL,
    result_status integer,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT commands_base_version_check CHECK ((base_version >= 0)),
    CONSTRAINT commands_kind_check CHECK (((kind)::text = ANY ((ARRAY['start'::character varying, 'stop'::character varying, 'break'::character varying, 'repair'::character varying])::text[])))
);


--
-- Name: commands_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.commands_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: commands_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.commands_id_seq OWNED BY public.commands.id;


--
-- Name: inspections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inspections (
    id bigint NOT NULL,
    lot_id bigint NOT NULL,
    work_order_id bigint NOT NULL,
    result character varying NOT NULL,
    defect_qty numeric(14,3) DEFAULT 0.0 NOT NULL,
    inspected_at timestamp with time zone DEFAULT now() NOT NULL,
    stock_move_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT inspections_defect_qty_check CHECK ((defect_qty >= (0)::numeric)),
    CONSTRAINT inspections_result_check CHECK (((result)::text = ANY ((ARRAY['pass'::character varying, 'fail'::character varying])::text[])))
);


--
-- Name: inspections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inspections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inspections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inspections_id_seq OWNED BY public.inspections.id;


--
-- Name: locations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.locations (
    id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    kind character varying NOT NULL,
    role character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT locations_kind_check CHECK (((kind)::text = ANY ((ARRAY['physical'::character varying, 'virtual'::character varying])::text[])))
);


--
-- Name: locations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.locations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: locations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.locations_id_seq OWNED BY public.locations.id;


--
-- Name: lots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lots (
    id bigint NOT NULL,
    product_id bigint NOT NULL,
    lot_no character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: lots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.lots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: lots_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.lots_id_seq OWNED BY public.lots.id;


--
-- Name: machine_state_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.machine_state_events (
    id bigint NOT NULL,
    machine_id bigint NOT NULL,
    command_id bigint,
    from_state character varying NOT NULL,
    to_state character varying NOT NULL,
    version integer NOT NULL,
    at timestamp with time zone NOT NULL
);


--
-- Name: machine_state_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.machine_state_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: machine_state_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.machine_state_events_id_seq OWNED BY public.machine_state_events.id;


--
-- Name: machines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.machines (
    id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    state character varying DEFAULT 'stopped'::character varying NOT NULL,
    version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT machines_state_check CHECK (((state)::text = ANY ((ARRAY['running'::character varying, 'stopped'::character varying, 'broken'::character varying])::text[]))),
    CONSTRAINT machines_version_check CHECK ((version >= 0))
);


--
-- Name: machines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.machines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: machines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.machines_id_seq OWNED BY public.machines.id;


--
-- Name: production_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.production_events (
    id bigint NOT NULL,
    machine_id bigint NOT NULL,
    work_order_id bigint NOT NULL,
    bucket_start timestamp with time zone NOT NULL,
    bucket_end timestamp with time zone NOT NULL,
    good_qty integer NOT NULL,
    defect_qty integer NOT NULL,
    machine_version integer NOT NULL,
    CONSTRAINT production_events_machine_version_check CHECK ((machine_version >= 0)),
    CONSTRAINT production_events_qty_check CHECK (((good_qty >= 0) AND (defect_qty >= 0)))
);


--
-- Name: production_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.production_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: production_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.production_events_id_seq OWNED BY public.production_events.id;


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id bigint NOT NULL,
    sku character varying NOT NULL,
    name character varying NOT NULL,
    uom character varying NOT NULL,
    kind character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT products_kind_check CHECK (((kind)::text = ANY ((ARRAY['raw'::character varying, 'wip'::character varying, 'fg'::character varying])::text[]))),
    CONSTRAINT products_uom_check CHECK ((btrim((uom)::text) <> ''::text))
);


--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.products_id_seq OWNED BY public.products.id;


--
-- Name: quants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quants (
    id bigint NOT NULL,
    product_id bigint NOT NULL,
    lot_id bigint,
    location_id bigint NOT NULL,
    qty numeric(14,3) DEFAULT 0.0 NOT NULL,
    negative_allowed boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT quants_physical_non_negative_check CHECK (((qty >= (0)::numeric) OR negative_allowed))
);


--
-- Name: quants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.quants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: quants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.quants_id_seq OWNED BY public.quants.id;


--
-- Name: sales_order_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sales_order_lines (
    id bigint NOT NULL,
    sales_order_id bigint NOT NULL,
    product_id bigint NOT NULL,
    ordered_qty numeric(14,3) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT sales_order_lines_ordered_qty_check CHECK ((ordered_qty > (0)::numeric))
);


--
-- Name: sales_order_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sales_order_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sales_order_lines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sales_order_lines_id_seq OWNED BY public.sales_order_lines.id;


--
-- Name: sales_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sales_orders (
    id bigint NOT NULL,
    so_no character varying NOT NULL,
    customer character varying NOT NULL,
    due_date date,
    status character varying DEFAULT 'open'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sales_orders_status_check CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'partial'::character varying, 'done'::character varying])::text[])))
);


--
-- Name: sales_orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sales_orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sales_orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sales_orders_id_seq OWNED BY public.sales_orders.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    ip_address character varying,
    user_agent character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sessions_id_seq OWNED BY public.sessions.id;


--
-- Name: stock_moves; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock_moves (
    id bigint NOT NULL,
    product_id bigint NOT NULL,
    lot_id bigint,
    from_location_id bigint NOT NULL,
    to_location_id bigint NOT NULL,
    qty numeric(14,3) NOT NULL,
    move_type character varying NOT NULL,
    ref_type character varying,
    ref_id bigint,
    idempotency_key character varying NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT stock_moves_locations_differ_check CHECK ((from_location_id <> to_location_id)),
    CONSTRAINT stock_moves_move_type_check CHECK (((move_type)::text = ANY ((ARRAY['receive'::character varying, 'putaway'::character varying, 'issue'::character varying, 'produce'::character varying, 'qc_pass'::character varying, 'qc_fail'::character varying, 'ship'::character varying])::text[]))),
    CONSTRAINT stock_moves_qty_check CHECK ((qty > (0)::numeric))
);


--
-- Name: stock_moves_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stock_moves_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stock_moves_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stock_moves_id_seq OWNED BY public.stock_moves.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    name character varying NOT NULL,
    password_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: work_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_orders (
    id bigint NOT NULL,
    code character varying NOT NULL,
    machine_id bigint NOT NULL,
    product character varying NOT NULL,
    target_qty integer NOT NULL,
    produced_qty integer DEFAULT 0 NOT NULL,
    status character varying DEFAULT 'queued'::character varying NOT NULL,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    product_id bigint NOT NULL,
    sales_order_line_id bigint,
    CONSTRAINT work_orders_produced_qty_check CHECK ((produced_qty >= 0)),
    CONSTRAINT work_orders_status_check CHECK (((status)::text = ANY ((ARRAY['queued'::character varying, 'active'::character varying, 'done'::character varying])::text[]))),
    CONSTRAINT work_orders_target_qty_check CHECK ((target_qty > 0))
);


--
-- Name: work_orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.work_orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: work_orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.work_orders_id_seq OWNED BY public.work_orders.id;


--
-- Name: bom_lines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bom_lines ALTER COLUMN id SET DEFAULT nextval('public.bom_lines_id_seq'::regclass);


--
-- Name: commands id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commands ALTER COLUMN id SET DEFAULT nextval('public.commands_id_seq'::regclass);


--
-- Name: inspections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inspections ALTER COLUMN id SET DEFAULT nextval('public.inspections_id_seq'::regclass);


--
-- Name: locations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locations ALTER COLUMN id SET DEFAULT nextval('public.locations_id_seq'::regclass);


--
-- Name: lots id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots ALTER COLUMN id SET DEFAULT nextval('public.lots_id_seq'::regclass);


--
-- Name: machine_state_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.machine_state_events ALTER COLUMN id SET DEFAULT nextval('public.machine_state_events_id_seq'::regclass);


--
-- Name: machines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.machines ALTER COLUMN id SET DEFAULT nextval('public.machines_id_seq'::regclass);


--
-- Name: production_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_events ALTER COLUMN id SET DEFAULT nextval('public.production_events_id_seq'::regclass);


--
-- Name: products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products ALTER COLUMN id SET DEFAULT nextval('public.products_id_seq'::regclass);


--
-- Name: quants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quants ALTER COLUMN id SET DEFAULT nextval('public.quants_id_seq'::regclass);


--
-- Name: sales_order_lines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_order_lines ALTER COLUMN id SET DEFAULT nextval('public.sales_order_lines_id_seq'::regclass);


--
-- Name: sales_orders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders ALTER COLUMN id SET DEFAULT nextval('public.sales_orders_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: stock_moves id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_moves ALTER COLUMN id SET DEFAULT nextval('public.stock_moves_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: work_orders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_orders ALTER COLUMN id SET DEFAULT nextval('public.work_orders_id_seq'::regclass);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: bom_lines bom_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bom_lines
    ADD CONSTRAINT bom_lines_pkey PRIMARY KEY (id);


--
-- Name: commands commands_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commands
    ADD CONSTRAINT commands_pkey PRIMARY KEY (id);


--
-- Name: inspections inspections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inspections
    ADD CONSTRAINT inspections_pkey PRIMARY KEY (id);


--
-- Name: locations locations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT locations_pkey PRIMARY KEY (id);


--
-- Name: lots lots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT lots_pkey PRIMARY KEY (id);


--
-- Name: machine_state_events machine_state_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.machine_state_events
    ADD CONSTRAINT machine_state_events_pkey PRIMARY KEY (id);


--
-- Name: machines machines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.machines
    ADD CONSTRAINT machines_pkey PRIMARY KEY (id);


--
-- Name: production_events production_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_events
    ADD CONSTRAINT production_events_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: quants quants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quants
    ADD CONSTRAINT quants_pkey PRIMARY KEY (id);


--
-- Name: sales_order_lines sales_order_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_order_lines
    ADD CONSTRAINT sales_order_lines_pkey PRIMARY KEY (id);


--
-- Name: sales_orders sales_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: stock_moves stock_moves_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_moves
    ADD CONSTRAINT stock_moves_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: work_orders work_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_orders
    ADD CONSTRAINT work_orders_pkey PRIMARY KEY (id);


--
-- Name: index_bom_lines_on_component_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bom_lines_on_component_id ON public.bom_lines USING btree (component_id);


--
-- Name: index_bom_lines_on_product_id_and_component_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_bom_lines_on_product_id_and_component_id ON public.bom_lines USING btree (product_id, component_id);


--
-- Name: index_commands_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_commands_on_idempotency_key ON public.commands USING btree (idempotency_key);


--
-- Name: index_commands_on_machine_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_commands_on_machine_id ON public.commands USING btree (machine_id);


--
-- Name: index_inspections_on_lot_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inspections_on_lot_id ON public.inspections USING btree (lot_id);


--
-- Name: index_inspections_on_stock_move_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_inspections_on_stock_move_id ON public.inspections USING btree (stock_move_id);


--
-- Name: index_inspections_on_work_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inspections_on_work_order_id ON public.inspections USING btree (work_order_id);


--
-- Name: index_locations_on_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_locations_on_code ON public.locations USING btree (code);


--
-- Name: index_lots_on_lot_no; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_lots_on_lot_no ON public.lots USING btree (lot_no);


--
-- Name: index_lots_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lots_on_product_id ON public.lots USING btree (product_id);


--
-- Name: index_machine_state_events_on_machine_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_machine_state_events_on_machine_id_and_version ON public.machine_state_events USING btree (machine_id, version);


--
-- Name: index_machines_on_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_machines_on_code ON public.machines USING btree (code);


--
-- Name: index_production_events_on_machine_id_and_bucket_start; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_production_events_on_machine_id_and_bucket_start ON public.production_events USING btree (machine_id, bucket_start);


--
-- Name: index_products_on_sku; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_products_on_sku ON public.products USING btree (sku);


--
-- Name: index_quants_on_location_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quants_on_location_id ON public.quants USING btree (location_id);


--
-- Name: index_quants_on_lot_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_quants_on_lot_id ON public.quants USING btree (lot_id);


--
-- Name: index_quants_unique_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_quants_unique_slot ON public.quants USING btree (product_id, COALESCE(lot_id, (0)::bigint), location_id);


--
-- Name: index_sales_order_lines_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sales_order_lines_on_product_id ON public.sales_order_lines USING btree (product_id);


--
-- Name: index_sales_order_lines_on_sales_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sales_order_lines_on_sales_order_id ON public.sales_order_lines USING btree (sales_order_id);


--
-- Name: index_sales_orders_on_so_no; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sales_orders_on_so_no ON public.sales_orders USING btree (so_no);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_stock_moves_on_from_location_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stock_moves_on_from_location_id ON public.stock_moves USING btree (from_location_id);


--
-- Name: index_stock_moves_on_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_stock_moves_on_idempotency_key ON public.stock_moves USING btree (idempotency_key);


--
-- Name: index_stock_moves_on_lot_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stock_moves_on_lot_id ON public.stock_moves USING btree (lot_id);


--
-- Name: index_stock_moves_on_product_id_and_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stock_moves_on_product_id_and_occurred_at ON public.stock_moves USING btree (product_id, occurred_at);


--
-- Name: index_stock_moves_on_ref_type_and_ref_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stock_moves_on_ref_type_and_ref_id ON public.stock_moves USING btree (ref_type, ref_id);


--
-- Name: index_stock_moves_on_to_location_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stock_moves_on_to_location_id ON public.stock_moves USING btree (to_location_id);


--
-- Name: index_users_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_name ON public.users USING btree (name);


--
-- Name: index_work_orders_on_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_work_orders_on_code ON public.work_orders USING btree (code);


--
-- Name: index_work_orders_on_id_and_machine_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_work_orders_on_id_and_machine_id ON public.work_orders USING btree (id, machine_id);


--
-- Name: index_work_orders_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_work_orders_on_product_id ON public.work_orders USING btree (product_id);


--
-- Name: index_work_orders_on_sales_order_line_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_work_orders_on_sales_order_line_id ON public.work_orders USING btree (sales_order_line_id);


--
-- Name: index_work_orders_one_active_per_machine; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_work_orders_one_active_per_machine ON public.work_orders USING btree (machine_id) WHERE ((status)::text = 'active'::text);


--
-- Name: stock_moves stock_moves_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stock_moves_no_truncate BEFORE TRUNCATE ON public.stock_moves FOR EACH STATEMENT EXECUTE FUNCTION public.stock_moves_append_only();


--
-- Name: stock_moves stock_moves_no_update_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stock_moves_no_update_delete BEFORE DELETE OR UPDATE ON public.stock_moves FOR EACH ROW EXECUTE FUNCTION public.stock_moves_append_only();


--
-- Name: production_events fk_production_events_work_order_machine; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_events
    ADD CONSTRAINT fk_production_events_work_order_machine FOREIGN KEY (work_order_id, machine_id) REFERENCES public.work_orders(id, machine_id);


--
-- Name: inspections fk_rails_244b04e584; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inspections
    ADD CONSTRAINT fk_rails_244b04e584 FOREIGN KEY (lot_id) REFERENCES public.lots(id);


--
-- Name: work_orders fk_rails_253ad21af4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_orders
    ADD CONSTRAINT fk_rails_253ad21af4 FOREIGN KEY (machine_id) REFERENCES public.machines(id);


--
-- Name: commands fk_rails_2a9f070333; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commands
    ADD CONSTRAINT fk_rails_2a9f070333 FOREIGN KEY (machine_id) REFERENCES public.machines(id);


--
-- Name: quants fk_rails_3bf78ae0e7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quants
    ADD CONSTRAINT fk_rails_3bf78ae0e7 FOREIGN KEY (location_id) REFERENCES public.locations(id);


--
-- Name: quants fk_rails_49a05fce0c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quants
    ADD CONSTRAINT fk_rails_49a05fce0c FOREIGN KEY (lot_id) REFERENCES public.lots(id);


--
-- Name: inspections fk_rails_57256f17c4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inspections
    ADD CONSTRAINT fk_rails_57256f17c4 FOREIGN KEY (stock_move_id) REFERENCES public.stock_moves(id);


--
-- Name: bom_lines fk_rails_6850bd5d47; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bom_lines
    ADD CONSTRAINT fk_rails_6850bd5d47 FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: lots fk_rails_7cbb66cb0f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT fk_rails_7cbb66cb0f FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: production_events fk_rails_85adf9ef9f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_events
    ADD CONSTRAINT fk_rails_85adf9ef9f FOREIGN KEY (work_order_id) REFERENCES public.work_orders(id);


--
-- Name: machine_state_events fk_rails_87fc7bfa18; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.machine_state_events
    ADD CONSTRAINT fk_rails_87fc7bfa18 FOREIGN KEY (machine_id) REFERENCES public.machines(id);


--
-- Name: sales_order_lines fk_rails_9551dd1dd1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_order_lines
    ADD CONSTRAINT fk_rails_9551dd1dd1 FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: stock_moves fk_rails_adba036fb4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_moves
    ADD CONSTRAINT fk_rails_adba036fb4 FOREIGN KEY (to_location_id) REFERENCES public.locations(id);


--
-- Name: stock_moves fk_rails_b4e7123387; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_moves
    ADD CONSTRAINT fk_rails_b4e7123387 FOREIGN KEY (from_location_id) REFERENCES public.locations(id);


--
-- Name: work_orders fk_rails_b89341f888; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_orders
    ADD CONSTRAINT fk_rails_b89341f888 FOREIGN KEY (sales_order_line_id) REFERENCES public.sales_order_lines(id);


--
-- Name: work_orders fk_rails_ba46ddfdab; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_orders
    ADD CONSTRAINT fk_rails_ba46ddfdab FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: quants fk_rails_bd2d50a1c4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quants
    ADD CONSTRAINT fk_rails_bd2d50a1c4 FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: bom_lines fk_rails_cae9efd8bd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bom_lines
    ADD CONSTRAINT fk_rails_cae9efd8bd FOREIGN KEY (component_id) REFERENCES public.products(id);


--
-- Name: production_events fk_rails_cf6321b693; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_events
    ADD CONSTRAINT fk_rails_cf6321b693 FOREIGN KEY (machine_id) REFERENCES public.machines(id);


--
-- Name: stock_moves fk_rails_d7c81d76af; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_moves
    ADD CONSTRAINT fk_rails_d7c81d76af FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: inspections fk_rails_da038cf67b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inspections
    ADD CONSTRAINT fk_rails_da038cf67b FOREIGN KEY (work_order_id) REFERENCES public.work_orders(id);


--
-- Name: machine_state_events fk_rails_da71a2c97e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.machine_state_events
    ADD CONSTRAINT fk_rails_da71a2c97e FOREIGN KEY (command_id) REFERENCES public.commands(id);


--
-- Name: stock_moves fk_rails_dfd88aadef; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_moves
    ADD CONSTRAINT fk_rails_dfd88aadef FOREIGN KEY (lot_id) REFERENCES public.lots(id);


--
-- Name: sales_order_lines fk_rails_e3a8c2303b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_order_lines
    ADD CONSTRAINT fk_rails_e3a8c2303b FOREIGN KEY (sales_order_id) REFERENCES public.sales_orders(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261008000010'),
('20261008000009'),
('20261008000008'),
('20261008000007'),
('20261008000006'),
('20261008000005'),
('20261008000004'),
('20261008000003'),
('20261008000002'),
('20261008000001'),
('20261007000004'),
('20261007000003'),
('20261007000002'),
('20261007000001'),
('20261006000005'),
('20261006000004'),
('20261006000003'),
('20261006000002'),
('20261006000001');

