const express = require('express');
const router  = express.Router();
const db      = require('../db');

router.get('/', async (req, res) => {
  try {
    // 每次访问先刷新批次状态
    

    const result = await db.query(`
      SELECT r.restaurant_name, m.material_name, m.unit,
             SUM(ib.remaining_quantity) AS total_remaining,
             MIN(ib.expiry_time)::DATE  AS earliest_expiry,
             COUNT(ib.batch_id)         AS batch_count,
             MAX(CASE WHEN ib.batch_status = 'near_expiry'      THEN 3
                      WHEN ib.batch_status = 'pending_disposal' THEN 2
                      ELSE 1 END) AS urgency
      FROM Inventory_Batch ib
      JOIN Purchase_Item pi ON pi.purchase_item_id = ib.purchase_item_id
      JOIN Purchase      pu ON pu.purchase_id      = pi.purchase_id
      JOIN Restaurant    r  ON r.restaurant_id     = pu.restaurant_id
      JOIN Material      m  ON m.material_id       = pi.material_id
      WHERE ib.batch_status NOT IN ('disposed','depleted')
      GROUP BY r.restaurant_name, m.material_name, m.unit
      ORDER BY urgency DESC, r.restaurant_name, m.material_name
    `);
    res.render('inventory/index', { inventory: result.rows });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.get('/purchases', async (req, res) => {
  try {
    const result = await db.query(`
      SELECT pu.purchase_id, pu.purchase_time::DATE AS date,
             pu.total_amount, pu.purchase_status,
             r.restaurant_name, s.supplier_name,
             COUNT(pi.purchase_item_id) AS line_items
      FROM Purchase pu
      JOIN Restaurant r ON r.restaurant_id = pu.restaurant_id
      JOIN Supplier   s ON s.supplier_id   = pu.supplier_id
      JOIN Purchase_Item pi ON pi.purchase_id = pu.purchase_id
      GROUP BY pu.purchase_id, pu.purchase_time, pu.total_amount,
               pu.purchase_status, r.restaurant_name, s.supplier_name
      ORDER BY pu.purchase_time DESC
    `);
    res.render('inventory/purchases', { purchases: result.rows, error: null });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.get('/purchases/new', async (req, res) => {
  try {
    const [restaurants, suppliers, materials] = await Promise.all([
      db.query('SELECT restaurant_id, restaurant_name FROM Restaurant'),
      db.query('SELECT supplier_id, supplier_name FROM Supplier'),
      db.query('SELECT material_id, material_name, unit FROM Material ORDER BY material_name'),
    ]);
    res.render('inventory/purchases_new', {
      restaurants: restaurants.rows, suppliers: suppliers.rows,
      materials: materials.rows, error: null,
    });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.post('/purchases', async (req, res) => {
  const client = await db.connect();
  try {
    await client.query('BEGIN');
    const { restaurant_id, supplier_id, purchase_status,
            material_id, quantity, unit_price, expiry_time } = req.body;

    const materialIds = [].concat(material_id);
    const quantities  = [].concat(quantity);
    const unitPrices  = [].concat(unit_price);
    const expiryTimes = [].concat(expiry_time);

    const total = materialIds.reduce((sum, _, i) =>
      sum + parseFloat(quantities[i]) * parseFloat(unitPrices[i]), 0);

    const purchaseRes = await client.query(
      `INSERT INTO Purchase (restaurant_id, supplier_id, total_amount, purchase_status)
       VALUES ($1,$2,$3,$4) RETURNING purchase_id`,
      [restaurant_id, supplier_id, total.toFixed(2), purchase_status]
    );
    const purchaseId = purchaseRes.rows[0].purchase_id;

    for (let i = 0; i < materialIds.length; i++) {
      const qty      = parseFloat(quantities[i]);
      const price    = parseFloat(unitPrices[i]);
      const subtotal = (qty * price).toFixed(2);

      const itemRes = await client.query(
        `INSERT INTO Purchase_Item (purchase_id, material_id, quantity, unit_price, subtotal)
         VALUES ($1,$2,$3,$4,$5) RETURNING purchase_item_id`,
        [purchaseId, materialIds[i], qty, price, subtotal]
      );
      const itemId = itemRes.rows[0].purchase_item_id;

      if (purchase_status === 'delivered') {
        await client.query(
          `INSERT INTO Inventory_Batch
           (purchase_item_id, received_quantity, remaining_quantity, expiry_time, batch_status)
           VALUES ($1,$2,$2,$3,'available')`,
          [itemId, qty, expiryTimes[i] || null]
        );
      }
    }

    await client.query('COMMIT');
    res.redirect('/inventory/purchases');
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(err);
    const [restaurants, suppliers, materials] = await Promise.all([
      db.query('SELECT restaurant_id, restaurant_name FROM Restaurant'),
      db.query('SELECT supplier_id, supplier_name FROM Supplier'),
      db.query('SELECT material_id, material_name, unit FROM Material ORDER BY material_name'),
    ]);
    res.render('inventory/purchases_new', {
      restaurants: restaurants.rows, suppliers: suppliers.rows,
      materials: materials.rows, error: err.message,
    });
  } finally { client.release(); }
});

router.post('/batch/:id/status', async (req, res) => {
  const { status } = req.body;
  await db.query(
    'UPDATE Inventory_Batch SET batch_status=$1 WHERE batch_id=$2',
    [status, req.params.id]
  );
  res.redirect('/inventory');
});

module.exports = router;

// 批次详情页
router.get('/batches', async (req, res) => {
  try {
    
    const result = await db.query(`
      SELECT ib.batch_id, ib.inbound_time::DATE AS inbound_date,
             ib.received_quantity, ib.remaining_quantity,
             ib.expiry_time::DATE AS expiry_date,
             ib.batch_status,
             m.material_name, m.unit,
             r.restaurant_name,
             pu.purchase_id
      FROM Inventory_Batch ib
      JOIN Purchase_Item pi ON pi.purchase_item_id = ib.purchase_item_id
      JOIN Purchase      pu ON pu.purchase_id      = pi.purchase_id
      JOIN Restaurant    r  ON r.restaurant_id     = pu.restaurant_id
      JOIN Material      m  ON m.material_id       = pi.material_id
      ORDER BY ib.batch_status DESC, ib.expiry_time ASC NULLS LAST
    `);
    res.render('inventory/batches', { batches: result.rows });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

// 销毁批次
router.post('/batch/:id/dispose', async (req, res) => {
  try {
    await db.query(`
      UPDATE Inventory_Batch
      SET batch_status = 'disposed', remaining_quantity = 0
      WHERE batch_id = $1
    `, [req.params.id]);
    res.redirect('/inventory/batches');
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

// 采购单详情
router.get('/purchases/:id', async (req, res) => {
  try {
    const [purchase, items] = await Promise.all([
      db.query(`
        SELECT pu.*, r.restaurant_name, s.supplier_name,
               s.contact_person, s.phone
        FROM Purchase pu
        JOIN Restaurant r ON r.restaurant_id = pu.restaurant_id
        JOIN Supplier   s ON s.supplier_id   = pu.supplier_id
        WHERE pu.purchase_id = $1
      `, [req.params.id]),
      db.query(`
        SELECT pi.purchase_item_id, pi.quantity, pi.unit_price, pi.subtotal,
               m.material_name, m.unit,
               ib.batch_id, ib.batch_status, ib.remaining_quantity,
               ib.expiry_time::DATE AS expiry_date
        FROM Purchase_Item pi
        JOIN Material m ON m.material_id = pi.material_id
        LEFT JOIN Inventory_Batch ib ON ib.purchase_item_id = pi.purchase_item_id
        WHERE pi.purchase_id = $1
        ORDER BY m.material_name
      `, [req.params.id]),
    ]);
    if (!purchase.rows.length) return res.status(404).send('Not found');
    res.render('inventory/purchase_show', {
      purchase: purchase.rows[0],
      items:    items.rows,
    });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

// 更新采购单状态
router.post('/purchases/:id/status', async (req, res) => {
  const { status } = req.body;
  const { id }     = req.params;
  const client     = await db.connect();
  try {
    await client.query('BEGIN');

    const cur = await client.query(
      'SELECT purchase_status, restaurant_id FROM Purchase WHERE purchase_id=$1', [id]
    );
    if (!cur.rows.length) { await client.query('ROLLBACK'); return res.status(404).send('Not found'); }

    const prevStatus = cur.rows[0].purchase_status;

    await client.query(
      'UPDATE Purchase SET purchase_status=$1 WHERE purchase_id=$2', [status, id]
    );

    // pending/confirmed → delivered 时自动生成 Inventory_Batch
    if (prevStatus !== 'delivered' && status === 'delivered') {
      const items = await client.query(
        `SELECT pi.purchase_item_id, pi.quantity
         FROM Purchase_Item pi
         WHERE pi.purchase_id = $1
           AND NOT EXISTS (
             SELECT 1 FROM Inventory_Batch ib
             WHERE ib.purchase_item_id = pi.purchase_item_id
           )`, [id]
      );
      for (const item of items.rows) {
        await client.query(
          `INSERT INTO Inventory_Batch
           (purchase_item_id, received_quantity, remaining_quantity, batch_status)
           VALUES ($1,$2,$2,'available')`,
          [item.purchase_item_id, item.quantity]
        );
      }
    }

    await client.query('COMMIT');
    res.redirect('/inventory/purchases/' + id);
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(err);
    res.redirect('/inventory/purchases/' + id);
  } finally { client.release(); }
});
