const express = require('express');
const router  = express.Router();
const db      = require('../db');

// 列表
router.get('/', async (req, res) => {
  try {
    const result = await db.query(`
      SELECT s.supplier_id, s.supplier_name, s.contact_person, s.phone,
             COUNT(p.purchase_id) AS purchase_count
      FROM Supplier s
      LEFT JOIN Purchase p ON p.supplier_id = s.supplier_id
      GROUP BY s.supplier_id
      ORDER BY s.supplier_id
    `);
    res.render('suppliers/index', { suppliers: result.rows, error: null });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

// 新增表单
router.get('/new', (req, res) => {
  res.render('suppliers/new', { error: null });
});

// 新增提交
router.post('/', async (req, res) => {
  const { supplier_name, contact_person, phone } = req.body;
  try {
    await db.query(
      `INSERT INTO Supplier (supplier_name, contact_person, phone) VALUES ($1, $2, $3)`,
      [supplier_name, contact_person || null, phone || null]
    );
    res.redirect('/suppliers');
  } catch (err) {
    console.error(err);
    res.render('suppliers/new', { error: err.message });
  }
});

// 编辑表单
router.get('/:id/edit', async (req, res) => {
  try {
    const result = await db.query('SELECT * FROM Supplier WHERE supplier_id = $1', [req.params.id]);
    if (!result.rows.length) return res.status(404).send('Not found');
    res.render('suppliers/edit', { supplier: result.rows[0], error: null });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

// 编辑提交
router.post('/:id/edit', async (req, res) => {
  const { supplier_name, contact_person, phone } = req.body;
  const { id } = req.params;
  try {
    await db.query(
      `UPDATE Supplier SET supplier_name=$1, contact_person=$2, phone=$3 WHERE supplier_id=$4`,
      [supplier_name, contact_person || null, phone || null, id]
    );
    res.redirect('/suppliers');
  } catch (err) {
    console.error(err);
    const result = await db.query('SELECT * FROM Supplier WHERE supplier_id = $1', [id]);
    res.render('suppliers/edit', { supplier: result.rows[0], error: err.message });
  }
});

// 删除
router.post('/:id/delete', async (req, res) => {
  try {
    await db.query('DELETE FROM Supplier WHERE supplier_id = $1', [req.params.id]);
    res.redirect('/suppliers');
  } catch (err) {
    console.error(err);
    res.redirect('/suppliers?error=Cannot+delete+supplier+with+existing+purchases');
  }
});

module.exports = router;
