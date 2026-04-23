--
-- PostgreSQL database dump
--

\restrict 4j935r7D5LyZUirBrdmYaH8MaNe0ya9Wc9xz1NLJURa2zM0XODNVimXGpPhScOb

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
-- Data for Name: Order; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."Order" (order_id, customer_id, restaurant_id, platform_id, card_id, order_time, order_type, order_status, total_amount, final_amount, points_used, points_earned, deduction_amount) FROM stdin;
1	1	1	\N	\N	2025-01-13 12:30:00	dine_in	completed	114.00	114.00	0	11	0.00
2	1	1	\N	1	2025-01-14 13:00:00	dine_in	completed	46.00	41.00	50	4	5.00
3	2	1	1	\N	2025-01-14 18:00:00	delivery	completed	76.00	76.00	0	7	0.00
4	2	1	\N	2	2025-01-15 11:30:00	takeout	completed	28.00	28.00	0	2	0.00
5	3	2	2	\N	2025-01-15 19:00:00	delivery	preparing	86.00	86.00	0	0	0.00
6	4	2	\N	\N	2025-01-16 12:00:00	dine_in	pending	36.00	36.00	0	0	0.00
7	15	1	\N	\N	2026-04-19 02:31:12.014576	dine_in	confirmed	56.00	56.00	0	5	0.00
8	1	1	\N	1	2026-04-20 00:57:05.009499	dine_in	completed	28.00	22.40	56	2	5.60
11	6	1	\N	4	2026-04-20 18:39:12.284706	takeout	completed	58.00	46.40	116	4	11.60
13	1	1	\N	1	2026-04-23 00:14:26.796335	dine_in	confirmed	56.00	46.00	100	4	10.00
14	1	1	\N	1	2026-04-23 00:52:48.77455	dine_in	confirmed	20.00	16.00	40	1	4.00
\.


--
-- Data for Name: customer; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.customer (customer_id, customer_name, phone, email) FROM stdin;
2	Bob Chen	138-0000-0002	bob@example.com
3	Carol Liu	138-0000-0003	carol@example.com
4	David Zhang	138-0000-0004	\N
5	Emma Wu	138-0000-0005	emma@example.com
6	Haruki Murakami	138-1001-0001	murakami@novels.jp
7	Lu Xun	138-1001-0002	luxun@literature.cn
8	Eileen Chang	138-1001-0003	eileenchang@story.cn
9	Franz Kafka	138-1001-0004	kafka@metamorphosis.de
10	Virginia Woolf	138-1001-0005	woolf@lighthouse.uk
11	George Orwell	138-1001-0006	orwell@bigbrother.uk
12	Ernest Hemingway	138-1001-0007	hemingway@oldman.us
13	Agatha Christie	138-1001-0008	christie@poirot.uk
14	Jorge Luis Borges	138-1001-0009	borges@labyrinths.ar
15	Simone de Beauvoir	138-1001-0010	beauvoir@secondsex.fr
1	Alice Wang	138-0000-0001	alice@example.com
\.


--
-- Data for Name: delivery_platform; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.delivery_platform (platform_id, platform_name, commission_rate) FROM stdin;
1	Deliveroo	0.1800
2	Uber Eats	0.1500
3	Hungry Panda	0.2000
4	Fantuan	0.1800
\.


--
-- Data for Name: inventory_batch; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.inventory_batch (batch_id, purchase_item_id, inbound_time, received_quantity, remaining_quantity, expiry_time, batch_status) FROM stdin;
55	55	2026-04-23 00:39:01.108286	20.00	20.00	2026-05-15 00:00:00	available
56	56	2026-04-23 00:39:01.108286	10.00	10.00	2027-12-30 00:00:00	available
2	2	2025-01-10 12:00:00	20.00	0.00	2026-01-20 00:00:00	disposed
3	3	2025-01-10 12:00:00	300.00	0.00	2026-01-25 00:00:00	disposed
10	10	2025-01-20 14:00:00	30.00	0.00	2026-01-27 00:00:00	disposed
14	14	2025-01-20 15:00:00	80.00	0.00	2026-02-05 00:00:00	disposed
58	63	2026-04-23 00:46:06.882249	30.00	30.00	2026-05-15 00:00:00	available
59	64	2026-04-23 00:46:06.882249	100.00	100.00	2027-12-30 00:00:00	available
60	65	2026-04-23 00:46:06.882249	50.00	50.00	2027-12-30 00:00:00	available
61	66	2026-04-23 00:46:06.882249	30.00	30.00	2027-12-30 00:00:00	available
4	4	2025-01-10 12:00:00	50.00	40.00	2026-07-01 00:00:00	available
9	9	2025-01-11 12:00:00	60.00	50.00	2026-08-01 00:00:00	available
13	13	2025-01-20 14:30:00	12.00	12.00	2026-07-20 00:00:00	available
17	17	2025-01-20 15:30:00	20.00	20.00	2026-07-20 00:00:00	available
18	18	2025-01-20 15:30:00	1500.00	1500.00	2026-06-20 00:00:00	available
19	19	2025-01-20 16:00:00	2000.00	2000.00	2026-12-31 00:00:00	available
20	20	2025-01-20 16:00:00	10.00	10.00	2026-09-30 00:00:00	available
21	21	2025-01-20 16:00:00	8.00	8.00	2026-12-31 00:00:00	available
23	23	2025-02-01 14:30:00	1000.00	1000.00	2026-12-31 00:00:00	available
24	24	2025-02-01 14:30:00	5.00	5.00	2026-10-01 00:00:00	available
25	25	2025-02-01 14:30:00	5.00	5.00	2026-12-31 00:00:00	available
26	26	2025-02-01 15:00:00	10.00	10.00	2026-08-01 00:00:00	available
27	27	2025-02-01 15:00:00	5.00	5.00	2026-12-31 00:00:00	available
11	11	2025-01-20 14:00:00	15.00	0.00	2026-02-20 00:00:00	disposed
1	1	2025-01-10 12:00:00	50.00	34.40	2027-04-17 02:33:31.043703	available
12	12	2025-01-20 14:00:00	60.00	60.00	2026-02-10 00:00:00	pending_disposal
15	15	2025-01-20 15:00:00	12.00	12.00	2026-02-15 00:00:00	pending_disposal
16	16	2025-01-20 15:30:00	5000.00	5000.00	2026-04-20 00:00:00	pending_disposal
22	22	2025-02-01 14:00:00	25.00	25.00	2026-02-08 00:00:00	pending_disposal
30	30	2026-04-20 01:07:23.492358	100.00	100.00	\N	available
31	31	2026-04-20 01:07:23.492358	200.00	200.00	\N	available
28	28	2025-02-01 15:30:00	60.00	60.00	2026-02-15 00:00:00	pending_disposal
29	29	2025-02-01 15:30:00	8.00	8.00	2026-02-20 00:00:00	pending_disposal
52	52	2026-04-20 18:40:57.563388	50.00	50.00	\N	available
54	54	2026-04-23 00:20:37.973216	10.00	10.00	2026-05-10 00:00:00	available
5	5	2025-01-10 14:00:00	30.00	0.00	2026-01-14 00:00:00	disposed
8	8	2025-01-11 12:00:00	40.00	0.00	2026-01-18 00:00:00	disposed
7	7	2025-01-12 14:00:00	40.00	31.86	2026-08-01 00:00:00	available
6	6	2025-01-12 14:00:00	100.00	78.85	2026-08-01 00:00:00	available
32	30	2026-04-20 01:09:21.789994	40.00	39.20	2026-04-27 00:00:00	near_expiry
57	57	2026-04-23 00:42:53.634559	20.00	19.94	2027-12-30 00:00:00	available
33	31	2026-04-20 01:09:21.789994	40.00	40.00	2026-04-27 00:00:00	near_expiry
34	32	2026-04-20 01:09:21.789994	15.00	15.00	2026-05-20 00:00:00	available
35	33	2026-04-20 01:09:21.789994	50.00	50.00	2026-05-10 00:00:00	available
36	34	2026-04-20 01:09:21.789994	15.00	15.00	2026-05-04 00:00:00	available
37	35	2026-04-20 01:09:21.789994	200.00	200.00	2026-05-10 00:00:00	available
38	36	2026-04-20 01:09:21.789994	40.00	40.00	2026-10-17 00:00:00	available
39	37	2026-04-20 01:09:21.789994	30.00	30.00	2026-04-27 00:00:00	near_expiry
40	38	2026-04-20 01:09:21.789994	100.00	100.00	2027-04-20 00:00:00	available
41	39	2026-04-20 01:09:21.789994	40.00	40.00	2027-04-20 00:00:00	available
42	40	2026-04-20 01:09:21.789994	45.00	45.00	2027-04-20 00:00:00	available
43	41	2026-04-20 01:09:21.789994	12.00	12.00	2026-10-17 00:00:00	available
44	42	2026-04-20 01:09:21.789994	80.00	80.00	2026-05-04 00:00:00	available
45	43	2026-04-20 01:09:21.789994	12.00	12.00	2026-05-04 00:00:00	available
46	44	2026-04-20 01:09:21.789994	5000.00	5000.00	2026-10-17 00:00:00	available
47	45	2026-04-20 01:09:21.789994	20.00	20.00	2027-04-20 00:00:00	available
48	46	2026-04-20 01:09:21.789994	1500.00	1500.00	2026-10-17 00:00:00	available
49	47	2026-04-20 01:09:21.789994	2000.00	2000.00	2027-04-20 00:00:00	available
50	48	2026-04-20 01:09:21.789994	10.00	10.00	2026-10-17 00:00:00	available
51	49	2026-04-20 01:09:21.789994	8.00	8.00	2027-04-20 00:00:00	available
53	53	2026-04-23 00:19:40.946536	50.00	50.00	2026-05-07 00:00:00	available
\.


--
-- Data for Name: material; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.material (material_id, material_name, unit) FROM stdin;
1	Chicken Breast	kg
2	Salmon Fillet	kg
3	Japonica Rice	kg
4	Cooking Oil	L
5	Soy Sauce	L
6	Spring Onion	kg
7	Egg	pcs
8	Wheat Flour	kg
9	Chicken Wings	kg
10	Milk	L
11	Tapioca Pearls	g
12	Sugar Syrup	L
13	Tea Leaves	g
14	Gochujang	kg
15	Honey	L
16	Garlic	kg
17	Potato	kg
18	Matcha Powder	g
19	Chocolate Sauce	L
20	Heavy Cream	L
\.


--
-- Data for Name: membership_card; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.membership_card (card_id, customer_id, card_level, points_balance, issue_date, card_status) FROM stdin;
2	2	silver	300	2024-09-15	active
3	3	platinum	5000	2023-03-20	active
5	7	platinum	8800	2023-01-01	active
6	8	silver	450	2024-11-20	active
7	10	silver	120	2025-01-05	active
8	13	gold	3300	2024-07-07	active
4	6	gold	1972	2024-03-15	active
1	1	gold	1250	2024-06-01	active
\.


--
-- Data for Name: menu; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.menu (menu_id, menu_name) FROM stdin;
1	Shared Standard Menu
\.


--
-- Data for Name: offers; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.offers (restaurant_id, product_id, availability_status) FROM stdin;
1	15	available
1	1	available
1	2	available
1	3	available
1	4	available
1	5	available
1	6	available
1	7	available
1	8	available
1	9	available
1	10	available
1	11	available
1	12	available
1	13	available
1	14	available
2	1	temporarily_sold_out
2	2	available
2	3	temporarily_sold_out
2	4	temporarily_sold_out
2	5	temporarily_sold_out
2	6	available
2	7	temporarily_sold_out
2	8	temporarily_sold_out
2	9	temporarily_sold_out
2	10	available
2	11	temporarily_sold_out
2	12	available
2	13	available
2	14	available
2	15	available
\.


--
-- Data for Name: order_item; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.order_item (order_item_id, order_id, product_id, quantity, unit_price, subtotal) FROM stdin;
1	1	1	2	28.00	56.00
2	1	2	1	58.00	58.00
3	2	1	1	28.00	28.00
4	2	3	1	18.00	18.00
5	3	2	1	58.00	58.00
6	3	3	1	18.00	18.00
7	4	1	1	28.00	28.00
8	5	2	1	58.00	58.00
9	5	1	1	28.00	28.00
10	6	3	2	18.00	36.00
11	7	1	2	28.00	56.00
12	8	1	1	28.00	28.00
13	11	2	1	58.00	58.00
14	13	1	2	28.00	56.00
15	14	1	2	10.00	20.00
\.


--
-- Data for Name: product; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.product (product_id, menu_id, product_name, price, category, listing_status) FROM stdin;
2	1	Salmon Sushi Set	58.00	Main	listed
3	1	Egg Fried Rice	18.00	Main	listed
4	1	Chicken Noodle Soup	22.00	Main	listed
5	1	Mixed Green Salad	15.00	Side	listed
6	1	Steamed White Rice	5.00	Side	listed
7	1	Spicy Korean Fried Chicken	38.00	Main	listed
8	1	Soy Sauce Korean Fried Chicken	38.00	Main	listed
9	1	French Fries	12.00	Side	listed
10	1	Matcha Ice Cream	18.00	Dessert	listed
11	1	Chocolate Lava Cake	22.00	Dessert	listed
12	1	Classic Milk Tea	15.00	Drink	listed
13	1	Brown Sugar Bubble Tea	18.00	Drink	listed
14	1	Matcha Latte	16.00	Drink	listed
15	1	Taro Milk Tea	16.00	Drink	listed
1	1	Teriyaki Chicken Bowl	10.00	Main	listed
\.


--
-- Data for Name: product_material; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.product_material (product_id, material_id, required_quantity) FROM stdin;
1	1	0.2000
1	3	0.1500
1	4	0.0200
1	5	0.0300
2	2	0.2000
2	3	0.1000
3	7	2.0000
3	3	0.1500
3	4	0.0200
4	1	0.1500
4	8	0.1000
4	6	0.0200
5	6	0.0500
6	3	0.1500
7	9	0.3500
7	14	0.0400
7	15	0.0200
7	16	0.0150
7	8	0.0500
8	9	0.3500
8	5	0.0400
8	15	0.0200
8	16	0.0150
8	8	0.0500
9	17	0.2000
9	4	0.0300
10	18	0.0150
10	12	0.0300
10	20	0.1000
11	19	0.0500
11	7	1.0000
11	8	0.0400
11	20	0.0300
12	10	0.1500
12	13	0.0080
12	12	0.0200
13	10	0.1500
13	11	0.0600
13	12	0.0300
13	13	0.0080
14	18	0.0120
14	10	0.2000
14	12	0.0150
15	10	0.1500
15	13	0.0080
15	12	0.0250
\.


--
-- Data for Name: purchase; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchase (purchase_id, restaurant_id, supplier_id, purchase_time, total_amount, purchase_status) FROM stdin;
1	1	1	2025-01-10 09:00:00	2700.00	delivered
2	1	2	2025-01-10 09:30:00	900.00	delivered
3	1	3	2025-01-12 10:00:00	600.00	delivered
4	2	1	2025-01-11 10:00:00	1560.00	delivered
5	1	1	2025-01-20 09:00:00	1350.00	delivered
6	1	4	2025-01-20 10:00:00	480.00	delivered
7	1	5	2025-01-20 10:30:00	760.00	delivered
8	1	6	2025-01-20 11:00:00	870.00	delivered
9	1	7	2025-01-20 11:30:00	920.00	delivered
10	1	2	2025-02-01 09:00:00	800.00	delivered
11	1	7	2025-02-01 10:00:00	490.00	delivered
12	2	4	2025-02-01 09:30:00	550.00	delivered
13	2	5	2025-02-01 10:30:00	560.00	delivered
14	1	1	2026-04-20 01:05:32.538261	760.00	delivered
15	2	1	2026-04-20 01:09:21.789994	3350.00	delivered
16	2	2	2026-04-20 01:09:21.789994	960.00	delivered
17	2	3	2026-04-20 01:09:21.789994	870.00	delivered
18	2	4	2026-04-20 01:09:21.789994	480.00	delivered
19	2	5	2026-04-20 01:09:21.789994	760.00	delivered
20	2	6	2026-04-20 01:09:21.789994	865.00	delivered
21	2	7	2026-04-20 01:09:21.789994	920.00	delivered
22	1	5	2026-04-20 18:40:40.51599	100.00	delivered
23	1	1	2026-04-23 00:19:40.946536	250.00	delivered
24	1	5	2026-04-23 00:20:37.973216	10.00	delivered
25	1	4	2026-04-23 00:39:01.108286	70.00	delivered
26	1	1	2026-04-23 00:42:53.634559	40.00	delivered
27	2	1	2026-04-23 00:44:32.700679	355.00	cancelled
28	1	1	2026-04-23 00:46:06.882249	370.00	delivered
\.


--
-- Data for Name: purchase_item; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.purchase_item (purchase_item_id, purchase_id, material_id, quantity, unit_price, subtotal) FROM stdin;
1	1	1	50.00	30.00	1500.00
2	1	6	20.00	5.00	100.00
3	1	7	300.00	2.00	600.00
4	1	8	50.00	10.00	500.00
5	2	2	30.00	30.00	900.00
6	3	3	100.00	4.00	400.00
7	3	4	40.00	5.00	200.00
8	4	1	40.00	30.00	1200.00
9	4	3	60.00	6.00	360.00
10	5	9	30.00	25.00	750.00
11	5	16	15.00	6.00	90.00
12	5	17	60.00	8.50	510.00
13	6	14	12.00	40.00	480.00
14	7	10	80.00	8.00	640.00
15	7	20	12.00	10.00	120.00
16	8	11	5000.00	0.08	400.00
17	8	12	20.00	12.00	240.00
18	8	13	1500.00	0.15	225.00
19	9	18	2000.00	0.20	400.00
20	9	19	10.00	28.00	280.00
21	9	15	8.00	30.00	240.00
22	10	2	25.00	32.00	800.00
23	11	18	1000.00	0.20	200.00
24	11	19	5.00	28.00	140.00
25	11	15	5.00	30.00	150.00
26	12	14	10.00	40.00	400.00
27	12	15	5.00	30.00	150.00
28	13	10	60.00	8.00	480.00
29	13	20	8.00	10.00	80.00
30	14	1	100.00	7.00	700.00
31	14	7	200.00	0.30	60.00
32	14	9	40.00	25.00	1000.00
33	14	1	40.00	30.00	1200.00
34	14	16	15.00	6.00	90.00
35	14	17	50.00	8.50	425.00
36	14	6	15.00	5.00	75.00
37	14	7	200.00	2.00	400.00
38	14	8	40.00	10.00	400.00
39	15	2	30.00	32.00	960.00
40	16	3	100.00	4.00	400.00
41	16	4	40.00	5.00	200.00
42	16	5	45.00	6.00	270.00
43	17	14	12.00	40.00	480.00
44	18	10	80.00	8.00	640.00
45	18	20	12.00	10.00	120.00
46	19	11	5000.00	0.08	400.00
47	19	12	20.00	12.00	240.00
48	19	13	1500.00	0.15	225.00
49	20	18	2000.00	0.20	400.00
50	20	19	10.00	28.00	280.00
51	20	15	8.00	30.00	240.00
52	22	15	50.00	2.00	100.00
53	23	1	50.00	5.00	250.00
54	24	10	10.00	1.00	10.00
55	25	1	20.00	3.00	60.00
56	25	4	10.00	1.00	10.00
57	26	5	20.00	2.00	40.00
58	27	1	30.00	3.00	90.00
59	27	16	10.00	0.50	5.00
60	27	5	5.00	2.00	10.00
61	27	3	100.00	1.00	100.00
62	27	4	50.00	3.00	150.00
63	28	1	30.00	3.00	90.00
64	28	4	100.00	2.00	200.00
65	28	5	50.00	1.00	50.00
66	28	3	30.00	1.00	30.00
\.


--
-- Data for Name: restaurant; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.restaurant (restaurant_id, restaurant_name, address, phone, menu_id) FROM stdin;
1	Downtown Branch	88 Nanjing Rd, Huangpu, Shanghai	021-1234-5678	1
2	Airport Branch	T2 Pudong International Airport	021-8765-4321	1
\.


--
-- Data for Name: supplier; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.supplier (supplier_id, supplier_name, contact_person, phone) FROM stdin;
1	Fresh Farm Co.	Li Wei	139-0001-0001
2	Ocean Seafood Ltd	Wang Fang	139-0001-0002
3	Grain & Oil Hub	Chen Jie	139-0001-0003
4	Han's Korean Imports	Kim Jinho	139-0002-0001
5	Dairy Fresh Ltd	Liu Mingzhu	139-0002-0002
6	Bubble Tea Supply Co.	Cai Xiaoling	139-0002-0003
7	Maison Gourmet	Pierre Dubois	139-0002-0004
\.


--
-- Name: Order_order_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public."Order_order_id_seq"', 14, true);


--
-- Name: customer_customer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.customer_customer_id_seq', 15, true);


--
-- Name: delivery_platform_platform_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.delivery_platform_platform_id_seq', 4, true);


--
-- Name: inventory_batch_batch_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.inventory_batch_batch_id_seq', 61, true);


--
-- Name: material_material_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.material_material_id_seq', 20, true);


--
-- Name: membership_card_card_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.membership_card_card_id_seq', 8, true);


--
-- Name: menu_menu_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.menu_menu_id_seq', 1, true);


--
-- Name: order_item_order_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.order_item_order_item_id_seq', 15, true);


--
-- Name: product_product_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.product_product_id_seq', 15, true);


--
-- Name: purchase_item_purchase_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchase_item_purchase_item_id_seq', 66, true);


--
-- Name: purchase_purchase_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.purchase_purchase_id_seq', 28, true);


--
-- Name: restaurant_restaurant_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.restaurant_restaurant_id_seq', 2, true);


--
-- Name: supplier_supplier_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.supplier_supplier_id_seq', 7, true);


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

\unrestrict 4j935r7D5LyZUirBrdmYaH8MaNe0ya9Wc9xz1NLJURa2zM0XODNVimXGpPhScOb

