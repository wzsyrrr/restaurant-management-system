const express = require('express');
const router  = express.Router();
const db      = require('../db');

router.get('/', async (req, res) => {
  try {
    const [customers, orders, products, inventory] = await Promise.all([
      db.query('SELECT COUNT(*) FROM Customer'),
      db.query('SELECT COUNT(*) FROM "Order"'),
      db.query('SELECT COUNT(*) FROM Product WHERE listing_status = $1', ['listed']),
      db.query(`SELECT COUNT(*) FROM Inventory_Batch
                WHERE batch_status NOT IN ('disposed','depleted')`),
    ]);
    res.render('index', {
      customerCount: customers.rows[0].count,
      orderCount:    orders.rows[0].count,
      productCount:  products.rows[0].count,
      batchCount:    inventory.rows[0].count,
    });
  } catch (err) {
    console.error(err);
    res.status(500).send('Database error');
  }
});

module.exports = router;
