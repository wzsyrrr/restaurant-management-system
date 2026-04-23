--
-- PostgreSQL database dump
--

\restrict NabxufQ8FbKbKgrVmKnzvln25vqITKCN5VoClkufvwrIRUpexs8TnZJXidJaySh

-- Dumped from database version 15.15
-- Dumped by pg_dump version 15.15

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
-- Name: fn_batch_depleted(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_batch_depleted() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Step 1: mark this batch as depleted
    UPDATE Inventory_Batch
    SET    batch_status = 'depleted'
    WHERE  batch_id     = NEW.batch_id
      AND  batch_status NOT IN ('disposed', 'depleted');

    -- Step 2: for each (restaurant, product) in Offers that:
    --   • the product uses the now-depleted material
    --   • the batch belongs to that restaurant
    --   • total remaining stock of that material for that restaurant = 0
    --   → set availability_status = 'temporarily_sold_out'
    UPDATE Offers o
    SET    availability_status = 'temporarily_sold_out'
    WHERE  o.availability_status = 'available'
      AND EXISTS (
          SELECT 1 FROM Product_Material pm
          WHERE  pm.product_id  = o.product_id
            AND  pm.material_id = (
                SELECT material_id FROM Purchase_Item
                WHERE  purchase_item_id = NEW.purchase_item_id
            )
      )
      AND EXISTS (
          SELECT 1 FROM Purchase_Item pi
          JOIN   Purchase pu ON pi.purchase_id = pu.purchase_id
          WHERE  pi.purchase_item_id = NEW.purchase_item_id
            AND  pu.restaurant_id   = o.restaurant_id
      )
      AND (
          SELECT COALESCE(SUM(ib2.remaining_quantity), 0)
          FROM   Inventory_Batch ib2
          JOIN   Purchase_Item pi2 ON ib2.purchase_item_id = pi2.purchase_item_id
          JOIN   Purchase      pu2 ON pi2.purchase_id      = pu2.purchase_id
          WHERE  pi2.material_id  = (
              SELECT material_id FROM Purchase_Item
              WHERE  purchase_item_id = NEW.purchase_item_id
          )
            AND  pu2.restaurant_id = o.restaurant_id
            AND  ib2.batch_status NOT IN ('disposed', 'depleted')
            AND  ib2.batch_id    != NEW.batch_id
      ) = 0;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_batch_depleted() OWNER TO postgres;

--
-- Name: fn_batch_restocked(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_batch_restocked() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE Offers o
    SET    availability_status = 'available'
    WHERE  o.availability_status = 'temporarily_sold_out'
      AND EXISTS (
          SELECT 1 FROM Product_Material pm
          WHERE  pm.product_id  = o.product_id
            AND  pm.material_id = (
                SELECT material_id FROM Purchase_Item
                WHERE  purchase_item_id = NEW.purchase_item_id
            )
      )
      AND EXISTS (
          SELECT 1 FROM Purchase_Item pi
          JOIN   Purchase pu ON pi.purchase_id = pu.purchase_id
          WHERE  pi.purchase_item_id = NEW.purchase_item_id
            AND  pu.restaurant_id   = o.restaurant_id
      );

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_batch_restocked() OWNER TO postgres;

--
-- Name: fn_check_offer_availability(integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_check_offer_availability(p_restaurant_id integer, p_product_id integer) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
DECLARE
    r_mat      RECORD;
    v_stock    NUMERIC;
BEGIN
    -- 遍历该菜品的每种原材料
    FOR r_mat IN
        SELECT pm.material_id, pm.required_quantity
        FROM   Product_Material pm
        WHERE  pm.product_id = p_product_id
    LOOP
        -- 查该门店该原材料的可用库存总量
        SELECT COALESCE(SUM(ib.remaining_quantity), 0)
        INTO   v_stock
        FROM   Inventory_Batch ib
        JOIN   Purchase_Item   pi ON pi.purchase_item_id = ib.purchase_item_id
        JOIN   Purchase        pu ON pu.purchase_id      = pi.purchase_id
        WHERE  pi.material_id     = r_mat.material_id
          AND  pu.restaurant_id   = p_restaurant_id
          AND  ib.batch_status   NOT IN ('disposed', 'depleted');

        -- 任意一种原材料不够一份 → 不可售
        IF v_stock < r_mat.required_quantity THEN
            RETURN 'temporarily_sold_out';
        END IF;
    END LOOP;

    RETURN 'available';
END;
$$;


ALTER FUNCTION public.fn_check_offer_availability(p_restaurant_id integer, p_product_id integer) OWNER TO postgres;

--
-- Name: fn_deduct_inventory_on_confirm(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_deduct_inventory_on_confirm() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    r_material   RECORD;
    r_batch      RECORD;
    v_needed     NUMERIC;
    v_deduct     NUMERIC;
    v_new_qty    NUMERIC;
BEGIN
    -- 只在 pending → confirmed 时触发
    IF OLD.order_status != 'pending' OR NEW.order_status != 'confirmed' THEN
        RETURN NEW;
    END IF;

    -- 汇总这张订单每种原材料的总需求量
    FOR r_material IN
        SELECT pm.material_id,
               SUM(oi.quantity * pm.required_quantity) AS total_needed
        FROM   Order_Item        oi
        JOIN   Product_Material  pm ON pm.product_id = oi.product_id
        WHERE  oi.order_id = NEW.order_id
        GROUP  BY pm.material_id
    LOOP
        v_needed := r_material.total_needed;

        -- FIFO：优先消耗最快过期 / 最早入库的批次
        FOR r_batch IN
            SELECT ib.batch_id, ib.remaining_quantity
            FROM   Inventory_Batch ib
            JOIN   Purchase_Item   pi ON pi.purchase_item_id = ib.purchase_item_id
            JOIN   Purchase        pu ON pu.purchase_id      = pi.purchase_id
            WHERE  pi.material_id      = r_material.material_id
              AND  pu.restaurant_id    = NEW.restaurant_id
              AND  ib.batch_status    NOT IN ('disposed','depleted')
              AND  ib.remaining_quantity > 0
            ORDER  BY ib.expiry_time ASC NULLS LAST, ib.inbound_time ASC
            FOR UPDATE
        LOOP
            EXIT WHEN v_needed <= 0;

            v_deduct  := LEAST(v_needed, r_batch.remaining_quantity);
            v_new_qty := ROUND(r_batch.remaining_quantity - v_deduct, 4);

            UPDATE Inventory_Batch
            SET    remaining_quantity = v_new_qty
            WHERE  batch_id = r_batch.batch_id;

            v_needed := ROUND(v_needed - v_deduct, 4);
        END LOOP;

        -- 库存不足时记录警告（不阻断订单，如需阻断改成 RAISE EXCEPTION）
        IF v_needed > 0 THEN
            RAISE WARNING 'Order % material % short by %',
                NEW.order_id, r_material.material_id, v_needed;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_deduct_inventory_on_confirm() OWNER TO postgres;

--
-- Name: fn_delivery_needs_platform(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_delivery_needs_platform() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.order_type = 'delivery' AND NEW.platform_id IS NULL THEN
        RAISE EXCEPTION 'Delivery orders must specify a platform_id';
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_delivery_needs_platform() OWNER TO postgres;

--
-- Name: fn_points_on_complete(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_points_on_complete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.order_status  = 'completed'
   AND OLD.order_status != 'completed'
   AND NEW.card_id IS NOT NULL THEN
        UPDATE Membership_Card
        SET    points_balance = points_balance
                              - NEW.points_used
                              + NEW.points_earned
        WHERE  card_id = NEW.card_id;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_points_on_complete() OWNER TO postgres;

--
-- Name: fn_refresh_batch_status(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_refresh_batch_status() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- 1. 剩余量为 0 → depleted
    UPDATE Inventory_Batch
    SET    batch_status = 'depleted'
    WHERE  remaining_quantity <= 0
      AND  batch_status NOT IN ('disposed', 'depleted');

    -- 2. 已过期超过 3 天还没处理 → pending_disposal
    UPDATE Inventory_Batch
    SET    batch_status = 'pending_disposal'
    WHERE  expiry_time < CURRENT_TIMESTAMP - INTERVAL '3 days'
      AND  batch_status NOT IN ('disposed', 'depleted', 'pending_disposal');

    -- 3. 7 天内到期 → near_expiry
    UPDATE Inventory_Batch
    SET    batch_status = 'near_expiry'
    WHERE  expiry_time BETWEEN CURRENT_TIMESTAMP
                           AND CURRENT_TIMESTAMP + INTERVAL '7 days'
      AND  remaining_quantity > 0
      AND  batch_status NOT IN ('disposed', 'depleted', 'pending_disposal');

    -- 4. 其余有库存、未过期 → available
    UPDATE Inventory_Batch
    SET    batch_status = 'available'
    WHERE  remaining_quantity > 0
      AND  (expiry_time IS NULL OR expiry_time > CURRENT_TIMESTAMP + INTERVAL '7 days')
      AND  batch_status NOT IN ('disposed', 'depleted');
END;
$$;


ALTER FUNCTION public.fn_refresh_batch_status() OWNER TO postgres;

--
-- Name: fn_refresh_offers_for_restaurant(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_refresh_offers_for_restaurant(p_restaurant_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    r_offer RECORD;
    v_status VARCHAR;
BEGIN
    FOR r_offer IN
        SELECT product_id FROM Offers
        WHERE  restaurant_id      = p_restaurant_id
          AND  availability_status != 'unavailable'   -- 手动下架的不自动改回来
    LOOP
        v_status := fn_check_offer_availability(p_restaurant_id, r_offer.product_id);

        UPDATE Offers
        SET    availability_status = v_status
        WHERE  restaurant_id = p_restaurant_id
          AND  product_id    = r_offer.product_id;
    END LOOP;
END;
$$;


ALTER FUNCTION public.fn_refresh_offers_for_restaurant(p_restaurant_id integer) OWNER TO postgres;

--
-- Name: fn_trigger_refresh_batch_status(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_trigger_refresh_batch_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- 归零 → depleted
    IF NEW.remaining_quantity <= 0
       AND NEW.batch_status NOT IN ('disposed', 'depleted') THEN
        NEW.batch_status := 'depleted';

    -- 已过期超 3 天 → pending_disposal
    ELSIF NEW.expiry_time IS NOT NULL
      AND NEW.expiry_time < CURRENT_TIMESTAMP - INTERVAL '3 days'
      AND NEW.batch_status NOT IN ('disposed', 'depleted', 'pending_disposal') THEN
        NEW.batch_status := 'pending_disposal';

    -- 7 天内到期 → near_expiry
    ELSIF NEW.expiry_time IS NOT NULL
      AND NEW.expiry_time BETWEEN CURRENT_TIMESTAMP
                               AND CURRENT_TIMESTAMP + INTERVAL '7 days'
      AND NEW.remaining_quantity > 0
      AND NEW.batch_status NOT IN ('disposed', 'depleted', 'pending_disposal') THEN
        NEW.batch_status := 'near_expiry';

    -- 正常 → available
    ELSIF NEW.remaining_quantity > 0
      AND (NEW.expiry_time IS NULL
           OR NEW.expiry_time > CURRENT_TIMESTAMP + INTERVAL '7 days')
      AND NEW.batch_status NOT IN ('disposed', 'depleted') THEN
        NEW.batch_status := 'available';
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_trigger_refresh_batch_status() OWNER TO postgres;

--
-- Name: fn_trigger_refresh_offers_on_batch(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_trigger_refresh_offers_on_batch() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_restaurant_id INTEGER;
BEGIN
    -- 找到这个批次属于哪家门店
    SELECT pu.restaurant_id INTO v_restaurant_id
    FROM   Purchase_Item pi
    JOIN   Purchase      pu ON pu.purchase_id = pi.purchase_id
    WHERE  pi.purchase_item_id = COALESCE(NEW.purchase_item_id, OLD.purchase_item_id);

    IF v_restaurant_id IS NOT NULL THEN
        PERFORM fn_refresh_offers_for_restaurant(v_restaurant_id);
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_trigger_refresh_offers_on_batch() OWNER TO postgres;

--
-- Name: fn_trigger_refresh_offers_on_order(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_trigger_refresh_offers_on_order() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF OLD.order_status != 'confirmed' AND NEW.order_status = 'confirmed' THEN
        PERFORM fn_refresh_offers_for_restaurant(NEW.restaurant_id);
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_trigger_refresh_offers_on_order() OWNER TO postgres;

--
-- Name: sp_place_order(integer, integer, character varying, integer, integer, jsonb); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.sp_place_order(IN p_customer_id integer, IN p_restaurant_id integer, IN p_order_type character varying, IN p_platform_id integer, IN p_points_to_use integer, IN p_items jsonb, OUT p_order_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_card_id        INTEGER;
    v_card_points    INTEGER;
    v_total          NUMERIC := 0;
    v_actual_points  INTEGER;
    v_deduction      NUMERIC;
    v_max_deduction  NUMERIC;
    v_final_deduction NUMERIC;
    v_final_amount   NUMERIC;
    v_points_earned  INTEGER;
    v_item           JSONB;
    v_product_id     INTEGER;
    v_quantity       INTEGER;
    v_price          NUMERIC;
    v_subtotal       NUMERIC;
BEGIN
    -- 1. 查会员卡
    SELECT card_id, points_balance
    INTO   v_card_id, v_card_points
    FROM   Membership_Card
    WHERE  customer_id = p_customer_id
      AND  card_status = 'active'
    LIMIT  1;

    -- 2. 计算订单总金额
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_product_id := (v_item->>'product_id')::INTEGER;
        v_quantity   := (v_item->>'quantity')::INTEGER;

        SELECT price INTO v_price FROM Product WHERE product_id = v_product_id;
        v_total := v_total + v_price * v_quantity;
    END LOOP;

    -- 3. 计算积分抵扣
    v_actual_points   := LEAST(COALESCE(p_points_to_use, 0), COALESCE(v_card_points, 0));
    v_deduction       := ROUND(v_actual_points / 10.0, 2);
    v_max_deduction   := ROUND(v_total * 0.2, 2);
    v_final_deduction := LEAST(v_deduction, v_max_deduction);
    v_actual_points   := ROUND(v_final_deduction * 10)::INTEGER;
    v_final_amount    := ROUND(v_total - v_final_deduction, 2);
    v_points_earned   := FLOOR(v_final_amount / 10)::INTEGER;

    -- 4. 插入 Order
    INSERT INTO "Order" (
        customer_id, restaurant_id, platform_id, card_id,
        order_type, order_status,
        total_amount, final_amount,
        points_used, points_earned, deduction_amount
    ) VALUES (
        p_customer_id, p_restaurant_id,
        CASE WHEN p_order_type = 'delivery' THEN p_platform_id ELSE NULL END,
        v_card_id, p_order_type, 'pending',
        v_total, v_final_amount,
        v_actual_points, v_points_earned, v_final_deduction
    ) RETURNING order_id INTO p_order_id;

    -- 5. 插入 Order_Item
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_product_id := (v_item->>'product_id')::INTEGER;
        v_quantity   := (v_item->>'quantity')::INTEGER;

        SELECT price INTO v_price FROM Product WHERE product_id = v_product_id;
        v_subtotal := ROUND(v_price * v_quantity, 2);

        INSERT INTO Order_Item (order_id, product_id, quantity, unit_price, subtotal)
        VALUES (p_order_id, v_product_id, v_quantity, v_price, v_subtotal);
    END LOOP;

    -- 6. 扣减积分余额（points_used 在下单时先扣，earned 在 completed 时加）
    IF v_card_id IS NOT NULL AND v_actual_points > 0 THEN
        UPDATE Membership_Card
        SET    points_balance = points_balance - v_actual_points
        WHERE  card_id = v_card_id;
    END IF;
END;
$$;


ALTER PROCEDURE public.sp_place_order(IN p_customer_id integer, IN p_restaurant_id integer, IN p_order_type character varying, IN p_platform_id integer, IN p_points_to_use integer, IN p_items jsonb, OUT p_order_id integer) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: Order; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."Order" (
    order_id integer NOT NULL,
    customer_id integer NOT NULL,
    restaurant_id integer NOT NULL,
    platform_id integer,
    card_id integer,
    order_time timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    order_type character varying(10) NOT NULL,
    order_status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    total_amount numeric(10,2) NOT NULL,
    final_amount numeric(10,2) NOT NULL,
    points_used integer DEFAULT 0 NOT NULL,
    points_earned integer DEFAULT 0 NOT NULL,
    deduction_amount numeric(10,2) DEFAULT 0.00 NOT NULL,
    CONSTRAINT "Order_order_status_check" CHECK (((order_status)::text = ANY ((ARRAY['pending'::character varying, 'confirmed'::character varying, 'preparing'::character varying, 'ready'::character varying, 'completed'::character varying, 'cancelled'::character varying])::text[]))),
    CONSTRAINT "Order_order_type_check" CHECK (((order_type)::text = ANY ((ARRAY['dine_in'::character varying, 'takeout'::character varying, 'delivery'::character varying])::text[])))
);


ALTER TABLE public."Order" OWNER TO postgres;

--
-- Name: Order_order_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public."Order_order_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public."Order_order_id_seq" OWNER TO postgres;

--
-- Name: Order_order_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public."Order_order_id_seq" OWNED BY public."Order".order_id;


--
-- Name: customer; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customer (
    customer_id integer NOT NULL,
    customer_name character varying(100) NOT NULL,
    phone character varying(20),
    email character varying(100)
);


ALTER TABLE public.customer OWNER TO postgres;

--
-- Name: customer_customer_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.customer_customer_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.customer_customer_id_seq OWNER TO postgres;

--
-- Name: customer_customer_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.customer_customer_id_seq OWNED BY public.customer.customer_id;


--
-- Name: delivery_platform; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.delivery_platform (
    platform_id integer NOT NULL,
    platform_name character varying(100) NOT NULL,
    commission_rate numeric(5,4) NOT NULL
);


ALTER TABLE public.delivery_platform OWNER TO postgres;

--
-- Name: delivery_platform_platform_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.delivery_platform_platform_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.delivery_platform_platform_id_seq OWNER TO postgres;

--
-- Name: delivery_platform_platform_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.delivery_platform_platform_id_seq OWNED BY public.delivery_platform.platform_id;


--
-- Name: inventory_batch; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.inventory_batch (
    batch_id integer NOT NULL,
    purchase_item_id integer NOT NULL,
    inbound_time timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    received_quantity numeric(10,2) NOT NULL,
    remaining_quantity numeric(10,2) NOT NULL,
    expiry_time timestamp without time zone,
    batch_status character varying(20) DEFAULT 'available'::character varying NOT NULL,
    CONSTRAINT inventory_batch_batch_status_check CHECK (((batch_status)::text = ANY ((ARRAY['available'::character varying, 'near_expiry'::character varying, 'pending_disposal'::character varying, 'disposed'::character varying, 'depleted'::character varying])::text[])))
);


ALTER TABLE public.inventory_batch OWNER TO postgres;

--
-- Name: inventory_batch_batch_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.inventory_batch_batch_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.inventory_batch_batch_id_seq OWNER TO postgres;

--
-- Name: inventory_batch_batch_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.inventory_batch_batch_id_seq OWNED BY public.inventory_batch.batch_id;


--
-- Name: material; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.material (
    material_id integer NOT NULL,
    material_name character varying(100) NOT NULL,
    unit character varying(20) NOT NULL
);


ALTER TABLE public.material OWNER TO postgres;

--
-- Name: material_material_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.material_material_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.material_material_id_seq OWNER TO postgres;

--
-- Name: material_material_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.material_material_id_seq OWNED BY public.material.material_id;


--
-- Name: membership_card; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.membership_card (
    card_id integer NOT NULL,
    customer_id integer NOT NULL,
    card_level character varying(20) DEFAULT 'silver'::character varying NOT NULL,
    points_balance integer DEFAULT 0 NOT NULL,
    issue_date date NOT NULL,
    card_status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    CONSTRAINT membership_card_card_level_check CHECK (((card_level)::text = ANY ((ARRAY['silver'::character varying, 'gold'::character varying, 'platinum'::character varying])::text[]))),
    CONSTRAINT membership_card_card_status_check CHECK (((card_status)::text = ANY ((ARRAY['active'::character varying, 'frozen'::character varying, 'expired'::character varying])::text[])))
);


ALTER TABLE public.membership_card OWNER TO postgres;

--
-- Name: membership_card_card_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.membership_card_card_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.membership_card_card_id_seq OWNER TO postgres;

--
-- Name: membership_card_card_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.membership_card_card_id_seq OWNED BY public.membership_card.card_id;


--
-- Name: menu; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.menu (
    menu_id integer NOT NULL,
    menu_name character varying(100) NOT NULL
);


ALTER TABLE public.menu OWNER TO postgres;

--
-- Name: menu_menu_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.menu_menu_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.menu_menu_id_seq OWNER TO postgres;

--
-- Name: menu_menu_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.menu_menu_id_seq OWNED BY public.menu.menu_id;


--
-- Name: offers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.offers (
    restaurant_id integer NOT NULL,
    product_id integer NOT NULL,
    availability_status character varying(30) DEFAULT 'available'::character varying NOT NULL,
    CONSTRAINT offers_availability_status_check CHECK (((availability_status)::text = ANY ((ARRAY['available'::character varying, 'unavailable'::character varying, 'temporarily_sold_out'::character varying])::text[])))
);


ALTER TABLE public.offers OWNER TO postgres;

--
-- Name: order_item; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.order_item (
    order_item_id integer NOT NULL,
    order_id integer NOT NULL,
    product_id integer NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    subtotal numeric(10,2) NOT NULL
);


ALTER TABLE public.order_item OWNER TO postgres;

--
-- Name: order_item_order_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.order_item_order_item_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.order_item_order_item_id_seq OWNER TO postgres;

--
-- Name: order_item_order_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.order_item_order_item_id_seq OWNED BY public.order_item.order_item_id;


--
-- Name: product; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.product (
    product_id integer NOT NULL,
    menu_id integer NOT NULL,
    product_name character varying(100) NOT NULL,
    price numeric(10,2) NOT NULL,
    category character varying(50),
    listing_status character varying(10) DEFAULT 'listed'::character varying NOT NULL,
    CONSTRAINT product_listing_status_check CHECK (((listing_status)::text = ANY ((ARRAY['listed'::character varying, 'unlisted'::character varying])::text[])))
);


ALTER TABLE public.product OWNER TO postgres;

--
-- Name: product_material; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.product_material (
    product_id integer NOT NULL,
    material_id integer NOT NULL,
    required_quantity numeric(10,4) NOT NULL
);


ALTER TABLE public.product_material OWNER TO postgres;

--
-- Name: product_product_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.product_product_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.product_product_id_seq OWNER TO postgres;

--
-- Name: product_product_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.product_product_id_seq OWNED BY public.product.product_id;


--
-- Name: purchase; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchase (
    purchase_id integer NOT NULL,
    restaurant_id integer NOT NULL,
    supplier_id integer NOT NULL,
    purchase_time timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    total_amount numeric(10,2) NOT NULL,
    purchase_status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    CONSTRAINT purchase_purchase_status_check CHECK (((purchase_status)::text = ANY ((ARRAY['pending'::character varying, 'confirmed'::character varying, 'delivered'::character varying, 'cancelled'::character varying])::text[])))
);


ALTER TABLE public.purchase OWNER TO postgres;

--
-- Name: purchase_item; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.purchase_item (
    purchase_item_id integer NOT NULL,
    purchase_id integer NOT NULL,
    material_id integer NOT NULL,
    quantity numeric(10,2) NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    subtotal numeric(10,2) NOT NULL
);


ALTER TABLE public.purchase_item OWNER TO postgres;

--
-- Name: purchase_item_purchase_item_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchase_item_purchase_item_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.purchase_item_purchase_item_id_seq OWNER TO postgres;

--
-- Name: purchase_item_purchase_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchase_item_purchase_item_id_seq OWNED BY public.purchase_item.purchase_item_id;


--
-- Name: purchase_purchase_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.purchase_purchase_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.purchase_purchase_id_seq OWNER TO postgres;

--
-- Name: purchase_purchase_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.purchase_purchase_id_seq OWNED BY public.purchase.purchase_id;


--
-- Name: restaurant; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.restaurant (
    restaurant_id integer NOT NULL,
    restaurant_name character varying(100) NOT NULL,
    address text,
    phone character varying(20),
    menu_id integer NOT NULL
);


ALTER TABLE public.restaurant OWNER TO postgres;

--
-- Name: restaurant_restaurant_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.restaurant_restaurant_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.restaurant_restaurant_id_seq OWNER TO postgres;

--
-- Name: restaurant_restaurant_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.restaurant_restaurant_id_seq OWNED BY public.restaurant.restaurant_id;


--
-- Name: supplier; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.supplier (
    supplier_id integer NOT NULL,
    supplier_name character varying(100) NOT NULL,
    contact_person character varying(100),
    phone character varying(20)
);


ALTER TABLE public.supplier OWNER TO postgres;

--
-- Name: supplier_supplier_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.supplier_supplier_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.supplier_supplier_id_seq OWNER TO postgres;

--
-- Name: supplier_supplier_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.supplier_supplier_id_seq OWNED BY public.supplier.supplier_id;


--
-- Name: Order order_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Order" ALTER COLUMN order_id SET DEFAULT nextval('public."Order_order_id_seq"'::regclass);


--
-- Name: customer customer_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer ALTER COLUMN customer_id SET DEFAULT nextval('public.customer_customer_id_seq'::regclass);


--
-- Name: delivery_platform platform_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_platform ALTER COLUMN platform_id SET DEFAULT nextval('public.delivery_platform_platform_id_seq'::regclass);


--
-- Name: inventory_batch batch_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inventory_batch ALTER COLUMN batch_id SET DEFAULT nextval('public.inventory_batch_batch_id_seq'::regclass);


--
-- Name: material material_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.material ALTER COLUMN material_id SET DEFAULT nextval('public.material_material_id_seq'::regclass);


--
-- Name: membership_card card_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.membership_card ALTER COLUMN card_id SET DEFAULT nextval('public.membership_card_card_id_seq'::regclass);


--
-- Name: menu menu_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.menu ALTER COLUMN menu_id SET DEFAULT nextval('public.menu_menu_id_seq'::regclass);


--
-- Name: order_item order_item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_item ALTER COLUMN order_item_id SET DEFAULT nextval('public.order_item_order_item_id_seq'::regclass);


--
-- Name: product product_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product ALTER COLUMN product_id SET DEFAULT nextval('public.product_product_id_seq'::regclass);


--
-- Name: purchase purchase_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase ALTER COLUMN purchase_id SET DEFAULT nextval('public.purchase_purchase_id_seq'::regclass);


--
-- Name: purchase_item purchase_item_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_item ALTER COLUMN purchase_item_id SET DEFAULT nextval('public.purchase_item_purchase_item_id_seq'::regclass);


--
-- Name: restaurant restaurant_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.restaurant ALTER COLUMN restaurant_id SET DEFAULT nextval('public.restaurant_restaurant_id_seq'::regclass);


--
-- Name: supplier supplier_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.supplier ALTER COLUMN supplier_id SET DEFAULT nextval('public.supplier_supplier_id_seq'::regclass);


--
-- Name: Order Order_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Order"
    ADD CONSTRAINT "Order_pkey" PRIMARY KEY (order_id);


--
-- Name: customer customer_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_pkey PRIMARY KEY (customer_id);


--
-- Name: delivery_platform delivery_platform_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_platform
    ADD CONSTRAINT delivery_platform_pkey PRIMARY KEY (platform_id);


--
-- Name: inventory_batch inventory_batch_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inventory_batch
    ADD CONSTRAINT inventory_batch_pkey PRIMARY KEY (batch_id);


--
-- Name: material material_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.material
    ADD CONSTRAINT material_pkey PRIMARY KEY (material_id);


--
-- Name: membership_card membership_card_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.membership_card
    ADD CONSTRAINT membership_card_pkey PRIMARY KEY (card_id);


--
-- Name: menu menu_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.menu
    ADD CONSTRAINT menu_pkey PRIMARY KEY (menu_id);


--
-- Name: offers offers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.offers
    ADD CONSTRAINT offers_pkey PRIMARY KEY (restaurant_id, product_id);


--
-- Name: order_item order_item_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_item
    ADD CONSTRAINT order_item_pkey PRIMARY KEY (order_item_id);


--
-- Name: product_material product_material_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_material
    ADD CONSTRAINT product_material_pkey PRIMARY KEY (product_id, material_id);


--
-- Name: product product_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product
    ADD CONSTRAINT product_pkey PRIMARY KEY (product_id);


--
-- Name: purchase_item purchase_item_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_item
    ADD CONSTRAINT purchase_item_pkey PRIMARY KEY (purchase_item_id);


--
-- Name: purchase purchase_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase
    ADD CONSTRAINT purchase_pkey PRIMARY KEY (purchase_id);


--
-- Name: restaurant restaurant_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.restaurant
    ADD CONSTRAINT restaurant_pkey PRIMARY KEY (restaurant_id);


--
-- Name: supplier supplier_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.supplier
    ADD CONSTRAINT supplier_pkey PRIMARY KEY (supplier_id);


--
-- Name: customer uq_customer_email; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT uq_customer_email UNIQUE (email);


--
-- Name: customer uq_customer_phone; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT uq_customer_phone UNIQUE (phone);


--
-- Name: delivery_platform uq_platform_name; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.delivery_platform
    ADD CONSTRAINT uq_platform_name UNIQUE (platform_name);


--
-- Name: supplier uq_supplier_phone; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.supplier
    ADD CONSTRAINT uq_supplier_phone UNIQUE (phone);


--
-- Name: idx_ib_item; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ib_item ON public.inventory_batch USING btree (purchase_item_id);


--
-- Name: idx_ib_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ib_status ON public.inventory_batch USING btree (batch_status);


--
-- Name: idx_mc_customer; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_mc_customer ON public.membership_card USING btree (customer_id);


--
-- Name: idx_offers_prod; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_offers_prod ON public.offers USING btree (product_id);


--
-- Name: idx_offers_rest; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_offers_rest ON public.offers USING btree (restaurant_id);


--
-- Name: idx_oi_order; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_oi_order ON public.order_item USING btree (order_id);


--
-- Name: idx_oi_product; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_oi_product ON public.order_item USING btree (product_id);


--
-- Name: idx_order_customer; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_order_customer ON public."Order" USING btree (customer_id);


--
-- Name: idx_order_platform; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_order_platform ON public."Order" USING btree (platform_id);


--
-- Name: idx_order_rest; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_order_rest ON public."Order" USING btree (restaurant_id);


--
-- Name: idx_pi_material; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_pi_material ON public.purchase_item USING btree (material_id);


--
-- Name: idx_pi_purchase; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_pi_purchase ON public.purchase_item USING btree (purchase_id);


--
-- Name: idx_pm_material; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_pm_material ON public.product_material USING btree (material_id);


--
-- Name: idx_pm_product; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_pm_product ON public.product_material USING btree (product_id);


--
-- Name: idx_product_menu; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_product_menu ON public.product USING btree (menu_id);


--
-- Name: idx_purchase_rest; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_purchase_rest ON public.purchase USING btree (restaurant_id);


--
-- Name: idx_purchase_sup; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_purchase_sup ON public.purchase USING btree (supplier_id);


--
-- Name: idx_restaurant_menu; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_restaurant_menu ON public.restaurant USING btree (menu_id);


--
-- Name: inventory_batch trg_auto_batch_status; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auto_batch_status BEFORE INSERT OR UPDATE OF remaining_quantity, expiry_time ON public.inventory_batch FOR EACH ROW EXECUTE FUNCTION public.fn_trigger_refresh_batch_status();


--
-- Name: Order trg_deduct_inventory; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_deduct_inventory AFTER UPDATE OF order_status ON public."Order" FOR EACH ROW EXECUTE FUNCTION public.fn_deduct_inventory_on_confirm();


--
-- Name: Order trg_delivery_needs_platform; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_delivery_needs_platform BEFORE INSERT ON public."Order" FOR EACH ROW EXECUTE FUNCTION public.fn_delivery_needs_platform();


--
-- Name: inventory_batch trg_offers_on_batch; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_offers_on_batch AFTER INSERT OR UPDATE OF remaining_quantity, batch_status ON public.inventory_batch FOR EACH ROW EXECUTE FUNCTION public.fn_trigger_refresh_offers_on_batch();


--
-- Name: Order trg_offers_on_order; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_offers_on_order AFTER UPDATE OF order_status ON public."Order" FOR EACH ROW EXECUTE FUNCTION public.fn_trigger_refresh_offers_on_order();


--
-- Name: Order trg_points_on_complete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_points_on_complete AFTER UPDATE OF order_status ON public."Order" FOR EACH ROW EXECUTE FUNCTION public.fn_points_on_complete();


--
-- Name: Order Order_card_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Order"
    ADD CONSTRAINT "Order_card_id_fkey" FOREIGN KEY (card_id) REFERENCES public.membership_card(card_id);


--
-- Name: Order Order_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Order"
    ADD CONSTRAINT "Order_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- Name: Order Order_platform_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Order"
    ADD CONSTRAINT "Order_platform_id_fkey" FOREIGN KEY (platform_id) REFERENCES public.delivery_platform(platform_id);


--
-- Name: Order Order_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Order"
    ADD CONSTRAINT "Order_restaurant_id_fkey" FOREIGN KEY (restaurant_id) REFERENCES public.restaurant(restaurant_id);


--
-- Name: inventory_batch inventory_batch_purchase_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.inventory_batch
    ADD CONSTRAINT inventory_batch_purchase_item_id_fkey FOREIGN KEY (purchase_item_id) REFERENCES public.purchase_item(purchase_item_id);


--
-- Name: membership_card membership_card_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.membership_card
    ADD CONSTRAINT membership_card_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- Name: offers offers_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.offers
    ADD CONSTRAINT offers_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.product(product_id);


--
-- Name: offers offers_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.offers
    ADD CONSTRAINT offers_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurant(restaurant_id);


--
-- Name: order_item order_item_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_item
    ADD CONSTRAINT order_item_order_id_fkey FOREIGN KEY (order_id) REFERENCES public."Order"(order_id);


--
-- Name: order_item order_item_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_item
    ADD CONSTRAINT order_item_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.product(product_id);


--
-- Name: product_material product_material_material_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_material
    ADD CONSTRAINT product_material_material_id_fkey FOREIGN KEY (material_id) REFERENCES public.material(material_id);


--
-- Name: product_material product_material_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_material
    ADD CONSTRAINT product_material_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.product(product_id);


--
-- Name: product product_menu_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product
    ADD CONSTRAINT product_menu_id_fkey FOREIGN KEY (menu_id) REFERENCES public.menu(menu_id);


--
-- Name: purchase_item purchase_item_material_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_item
    ADD CONSTRAINT purchase_item_material_id_fkey FOREIGN KEY (material_id) REFERENCES public.material(material_id);


--
-- Name: purchase_item purchase_item_purchase_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase_item
    ADD CONSTRAINT purchase_item_purchase_id_fkey FOREIGN KEY (purchase_id) REFERENCES public.purchase(purchase_id);


--
-- Name: purchase purchase_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase
    ADD CONSTRAINT purchase_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurant(restaurant_id);


--
-- Name: purchase purchase_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.purchase
    ADD CONSTRAINT purchase_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.supplier(supplier_id);


--
-- Name: restaurant restaurant_menu_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.restaurant
    ADD CONSTRAINT restaurant_menu_id_fkey FOREIGN KEY (menu_id) REFERENCES public.menu(menu_id);


--
-- PostgreSQL database dump complete
--

\unrestrict NabxufQ8FbKbKgrVmKnzvln25vqITKCN5VoClkufvwrIRUpexs8TnZJXidJaySh

