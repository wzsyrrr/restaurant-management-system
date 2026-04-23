const express = require('express');
const router  = express.Router();
const db      = require('../db');

router.get('/', async (req, res) => {
  try {
    const result = await db.query(`
      SELECT c.customer_id, c.customer_name, c.phone, c.email,
             mc.card_id, mc.card_level, mc.points_balance, mc.card_status
      FROM Customer c
      LEFT JOIN Membership_Card mc ON mc.customer_id = c.customer_id
      ORDER BY c.customer_id
    `);
    res.render('customers/index', { customers: result.rows, error: null });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.get('/new', (req, res) => {
  res.render('customers/new', { error: null });
});

router.post('/', async (req, res) => {
  const client = await db.connect();
  try {
    await client.query('BEGIN');
    const { customer_name, phone, email, issue_card, card_level } = req.body;
    const result = await client.query(
      `INSERT INTO Customer (customer_name, phone, email) VALUES ($1,$2,$3) RETURNING customer_id`,
      [customer_name, phone || null, email || null]
    );
    const customerId = result.rows[0].customer_id;
    if (issue_card === 'yes') {
      await client.query(
        `INSERT INTO Membership_Card (customer_id, card_level, points_balance, issue_date, card_status)
         VALUES ($1,$2,0,CURRENT_DATE,'active')`,
        [customerId, card_level || 'silver']
      );
    }
    await client.query('COMMIT');
    res.redirect('/customers/' + customerId);
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(err);
    res.render('customers/new', { error: err.message });
  } finally { client.release(); }
});

router.get('/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const [customer, orders, card] = await Promise.all([
      db.query('SELECT * FROM Customer WHERE customer_id = $1', [id]),
      db.query(`SELECT o.order_id, o.order_time, o.order_type, o.order_status,
                       o.total_amount, o.final_amount, o.points_earned, o.points_used
                FROM "Order" o WHERE o.customer_id = $1 ORDER BY o.order_time DESC`, [id]),
      db.query('SELECT * FROM Membership_Card WHERE customer_id = $1', [id]),
    ]);
    if (!customer.rows.length) return res.status(404).send('Not found');
    res.render('customers/show', {
      customer: customer.rows[0], orders: orders.rows,
      card: card.rows[0] || null, error: null,
    });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.get('/:id/edit', async (req, res) => {
  try {
    const { id } = req.params;
    const [customer, card] = await Promise.all([
      db.query('SELECT * FROM Customer WHERE customer_id = $1', [id]),
      db.query('SELECT * FROM Membership_Card WHERE customer_id = $1', [id]),
    ]);
    if (!customer.rows.length) return res.status(404).send('Not found');
    res.render('customers/edit', {
      customer: customer.rows[0], card: card.rows[0] || null, error: null,
    });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.post('/:id/edit', async (req, res) => {
  const { customer_name, phone, email } = req.body;
  const { id } = req.params;
  try {
    await db.query(
      `UPDATE Customer SET customer_name=$1, phone=$2, email=$3 WHERE customer_id=$4`,
      [customer_name, phone || null, email || null, id]
    );
    res.redirect('/customers/' + id);
  } catch (err) {
    console.error(err);
    const [customer, card] = await Promise.all([
      db.query('SELECT * FROM Customer WHERE customer_id=$1', [id]),
      db.query('SELECT * FROM Membership_Card WHERE customer_id=$1', [id]),
    ]);
    res.render('customers/edit', {
      customer: customer.rows[0], card: card.rows[0] || null, error: err.message,
    });
  }
});

router.post('/:id/card/new', async (req, res) => {
  const { card_level } = req.body;
  try {
    await db.query(
      `INSERT INTO Membership_Card (customer_id, card_level, points_balance, issue_date, card_status)
       VALUES ($1,$2,0,CURRENT_DATE,'active')`,
      [req.params.id, card_level]
    );
    res.redirect('/customers/' + req.params.id + '/edit');
  } catch (err) { console.error(err); res.redirect('/customers/' + req.params.id + '/edit'); }
});

router.post('/:id/card/points', async (req, res) => {
  const { delta } = req.body;
  try {
    await db.query(
      `UPDATE Membership_Card SET points_balance = GREATEST(0, points_balance + $1)
       WHERE customer_id = $2`,
      [parseInt(delta), req.params.id]
    );
    res.redirect('/customers/' + req.params.id + '/edit');
  } catch (err) { console.error(err); res.redirect('/customers/' + req.params.id + '/edit'); }
});

router.post('/:id/card/toggle', async (req, res) => {
  await db.query(
    `UPDATE Membership_Card
     SET card_status = CASE WHEN card_status='active' THEN 'frozen' ELSE 'active' END
     WHERE customer_id = $1`,
    [req.params.id]
  );
  res.redirect('/customers/' + req.params.id + '/edit');
});

router.post('/:id/card/upgrade', async (req, res) => {
  const { card_level } = req.body;
  await db.query(
    `UPDATE Membership_Card SET card_level=$1 WHERE customer_id=$2`,
    [card_level, req.params.id]
  );
  res.redirect('/customers/' + req.params.id + '/edit');
});

module.exports = router;
