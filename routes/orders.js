const express = require('express');
const router  = express.Router();
const db      = require('../db');

router.get('/', async (req, res) => {
  try {
    const result = await db.query(`
      SELECT o.order_id, o.order_time, o.order_type, o.order_status,
             o.total_amount, o.final_amount,
             c.customer_name, r.restaurant_name, dp.platform_name
      FROM "Order" o
      JOIN Customer   c  ON c.customer_id   = o.customer_id
      JOIN Restaurant r  ON r.restaurant_id = o.restaurant_id
      LEFT JOIN Delivery_Platform dp ON dp.platform_id = o.platform_id
      ORDER BY o.order_time DESC
    `);
    res.render('orders/index', { orders: result.rows, error: null });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.get('/new', async (req, res) => {
  try {
    const [customers, restaurants, products, platforms] = await Promise.all([
      db.query(`
        SELECT c.customer_id, c.customer_name,
               mc.card_id, mc.card_level, mc.points_balance
        FROM Customer c
        LEFT JOIN Membership_Card mc
          ON mc.customer_id = c.customer_id AND mc.card_status = 'active'
        ORDER BY c.customer_name
      `),
      db.query('SELECT restaurant_id, restaurant_name FROM Restaurant'),
      db.query(`SELECT product_id, product_name, price, category
                FROM Product WHERE listing_status='listed'
                ORDER BY category, product_name`),
      db.query('SELECT platform_id, platform_name FROM Delivery_Platform'),
    ]);
    res.render('orders/new', {
      customers: customers.rows, restaurants: restaurants.rows,
      products: products.rows, platforms: platforms.rows, error: null,
    });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.post('/', async (req, res) => {
  try {
    const { customer_id, restaurant_id, order_type,
            platform_id, product_id, quantity, points_to_use } = req.body;

    const productIds = [].concat(product_id);
    const quantities = [].concat(quantity).map(Number);

    // 构建 JSONB items 数组
    const items = productIds.map((pid, i) => ({
      product_id: parseInt(pid),
      quantity:   quantities[i],
    }));

    // 调用存储过程
    const result = await db.query(
      `CALL sp_place_order($1,$2,$3,$4,$5,$6::jsonb, NULL)`,
      [customer_id, restaurant_id, order_type,
       platform_id || null,
       parseInt(points_to_use) || 0,
       JSON.stringify(items)]
    );

    // PostgreSQL CALL 返回 OUT 参数在第一行
    const orderId = result.rows[0].p_order_id;
    res.redirect('/orders/' + orderId);
  } catch (err) {
    console.error(err);
    const [customers, restaurants, products, platforms] = await Promise.all([
      db.query(`SELECT c.customer_id, c.customer_name,
                       mc.card_id, mc.card_level, mc.points_balance
                FROM Customer c
                LEFT JOIN Membership_Card mc
                  ON mc.customer_id = c.customer_id AND mc.card_status = 'active'
                ORDER BY c.customer_name`),
      db.query('SELECT restaurant_id, restaurant_name FROM Restaurant'),
      db.query(`SELECT product_id, product_name, price, category FROM Product
                WHERE listing_status='listed' ORDER BY category, product_name`),
      db.query('SELECT platform_id, platform_name FROM Delivery_Platform'),
    ]);
    res.render('orders/new', { customers: customers.rows, restaurants: restaurants.rows,
      products: products.rows, platforms: platforms.rows, error: err.message });
  }
});

router.get('/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const [order, items] = await Promise.all([
      db.query(`
        SELECT o.*, c.customer_name, r.restaurant_name,
               dp.platform_name, mc.card_level
        FROM "Order" o
        JOIN Customer   c  ON c.customer_id   = o.customer_id
        JOIN Restaurant r  ON r.restaurant_id = o.restaurant_id
        LEFT JOIN Delivery_Platform dp ON dp.platform_id = o.platform_id
        LEFT JOIN Membership_Card   mc ON mc.card_id     = o.card_id
        WHERE o.order_id = $1`, [id]),
      db.query(`
        SELECT oi.quantity, oi.unit_price, oi.subtotal, p.product_name, p.category
        FROM Order_Item oi
        JOIN Product p ON p.product_id = oi.product_id
        WHERE oi.order_id = $1`, [id]),
    ]);
    if (!order.rows.length) return res.status(404).send('Not found');
    res.render('orders/show', { order: order.rows[0], items: items.rows, error: null });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.post('/:id/status', async (req, res) => {
  try {
    await db.query(
      'UPDATE "Order" SET order_status=$1 WHERE order_id=$2',
      [req.body.status, req.params.id]
    );
    res.redirect('/orders/' + req.params.id);
  } catch (err) { console.error(err); res.redirect('/orders/' + req.params.id); }
});

router.post('/:id/cancel', async (req, res) => {
  await db.query(
    `UPDATE "Order" SET order_status='cancelled' WHERE order_id=$1`, [req.params.id]
  );
  res.redirect('/orders/' + req.params.id);
});

module.exports = router;
