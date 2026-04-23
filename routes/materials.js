const express = require('express');
const router  = express.Router();
const db      = require('../db');

router.get('/', async (req, res) => {
  try {
    const result = await db.query(`
      SELECT m.material_id, m.material_name, m.unit,
             COUNT(DISTINCT pm.product_id)        AS used_in_products,
             COUNT(DISTINCT pi.purchase_item_id)  AS purchase_count
      FROM Material m
      LEFT JOIN Product_Material pm ON pm.material_id = m.material_id
      LEFT JOIN Purchase_Item    pi ON pi.material_id = m.material_id
      GROUP BY m.material_id
      ORDER BY m.material_name
    `);
    res.render('materials/index', { materials: result.rows, error: null });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.get('/new', (req, res) => {
  res.render('materials/new', { error: null });
});

router.post('/', async (req, res) => {
  const { material_name, unit } = req.body;
  try {
    await db.query(
      'INSERT INTO Material (material_name, unit) VALUES ($1,$2)',
      [material_name, unit]
    );
    res.redirect('/materials');
  } catch (err) {
    console.error(err);
    res.render('materials/new', { error: err.message });
  }
});

router.get('/:id/edit', async (req, res) => {
  try {
    const result = await db.query('SELECT * FROM Material WHERE material_id=$1', [req.params.id]);
    if (!result.rows.length) return res.status(404).send('Not found');
    res.render('materials/edit', { material: result.rows[0], error: null });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.post('/:id/edit', async (req, res) => {
  const { material_name, unit } = req.body;
  const { id } = req.params;
  try {
    await db.query(
      'UPDATE Material SET material_name=$1, unit=$2 WHERE material_id=$3',
      [material_name, unit, id]
    );
    res.redirect('/materials');
  } catch (err) {
    console.error(err);
    const result = await db.query('SELECT * FROM Material WHERE material_id=$1', [id]);
    res.render('materials/edit', { material: result.rows[0], error: err.message });
  }
});

router.post('/:id/delete', async (req, res) => {
  try {
    await db.query('DELETE FROM Material WHERE material_id=$1', [req.params.id]);
    res.redirect('/materials');
  } catch (err) {
    console.error(err);
    res.redirect('/materials?error=Cannot+delete+material+currently+in+use');
  }
});

module.exports = router;
