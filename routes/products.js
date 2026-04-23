const express = require('express');
const router  = express.Router();
const db      = require('../db');

router.get('/', async (req, res) => {
  try {
    const result = await db.query(`
      SELECT p.product_id, p.product_name, p.price, p.category,
             p.listing_status,
             MAX(CASE WHEN r.restaurant_name = 'Downtown Branch'
                 THEN o.availability_status END) AS downtown_status,
             MAX(CASE WHEN r.restaurant_name = 'Airport Branch'
                 THEN o.availability_status END) AS airport_status
      FROM Product p
      LEFT JOIN Offers     o ON o.product_id    = p.product_id
      LEFT JOIN Restaurant r ON r.restaurant_id = o.restaurant_id
      GROUP BY p.product_id, p.product_name, p.price,
               p.category, p.listing_status
      ORDER BY p.category, p.product_name
    `);
    res.render('products/index', { products: result.rows, error: null });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.get('/new', async (req, res) => {
  const menus = await db.query('SELECT menu_id, menu_name FROM Menu');
  res.render('products/new', { menus: menus.rows, error: null });
});

router.post('/', async (req, res) => {
  const { menu_id, product_name, price, category, listing_status } = req.body;
  try {
    const result = await db.query(
      `INSERT INTO Product (menu_id, product_name, price, category, listing_status)
       VALUES ($1,$2,$3,$4,$5) RETURNING product_id`,
      [menu_id, product_name, price, category, listing_status || 'listed']
    );
    const productId = result.rows[0].product_id;
    // 自动加入所有门店的 Offers
    await db.query(
      `INSERT INTO Offers (restaurant_id, product_id)
       SELECT restaurant_id, $1 FROM Restaurant`,
      [productId]
    );
    res.redirect('/products');
  } catch (err) {
    console.error(err);
    const menus = await db.query('SELECT menu_id, menu_name FROM Menu');
    res.render('products/new', { menus: menus.rows, error: err.message });
  }
});

router.get('/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const [product, materials, offers] = await Promise.all([
      db.query('SELECT * FROM Product WHERE product_id = $1', [id]),
      db.query(`SELECT m.material_name, m.unit, pm.required_quantity
                FROM Product_Material pm
                JOIN Material m ON m.material_id = pm.material_id
                WHERE pm.product_id = $1`, [id]),
      db.query(`SELECT r.restaurant_name, o.availability_status
                FROM Offers o
                JOIN Restaurant r ON r.restaurant_id = o.restaurant_id
                WHERE o.product_id = $1`, [id]),
    ]);
    if (!product.rows.length) return res.status(404).send('Not found');
    res.render('products/show', {
      product: product.rows[0], materials: materials.rows,
      offers: offers.rows, error: null,
    });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.get('/:id/edit', async (req, res) => {
  try {
    const [product, menus] = await Promise.all([
      db.query('SELECT * FROM Product WHERE product_id = $1', [req.params.id]),
      db.query('SELECT menu_id, menu_name FROM Menu'),
    ]);
    if (!product.rows.length) return res.status(404).send('Not found');
    res.render('products/edit', { product: product.rows[0], menus: menus.rows, error: null });
  } catch (err) { console.error(err); res.status(500).send('Database error'); }
});

router.post('/:id/edit', async (req, res) => {
  const { id } = req.params;
  const { product_name, price, category, listing_status } = req.body;
  try {
    await db.query(
      `UPDATE Product SET product_name=$1, price=$2, category=$3, listing_status=$4
       WHERE product_id=$5`,
      [product_name, price, category, listing_status, id]
    );
    res.redirect('/products/' + id);
  } catch (err) {
    console.error(err);
    const [product, menus] = await Promise.all([
      db.query('SELECT * FROM Product WHERE product_id=$1', [id]),
      db.query('SELECT menu_id, menu_name FROM Menu'),
    ]);
    res.render('products/edit', { product: product.rows[0], menus: menus.rows, error: err.message });
  }
});

router.post('/:id/toggle', async (req, res) => {
  await db.query(`
    UPDATE Product
    SET listing_status = CASE WHEN listing_status='listed' THEN 'unlisted' ELSE 'listed' END
    WHERE product_id = $1`, [req.params.id]);
  res.redirect('/products');
});

router.post('/:id/delete', async (req, res) => {
  try {
    await db.query('DELETE FROM Product WHERE product_id=$1', [req.params.id]);
    res.redirect('/products');
  } catch (err) {
    res.redirect('/products?error=Cannot+delete+product+with+existing+orders');
  }
});

module.exports = router;
