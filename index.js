const express = require('express');
const app = express();

app.set('view engine', 'ejs');
app.set('views', './views');
app.use(express.static('public'));
app.use(express.urlencoded({ extended: true }));
app.use(express.json());

app.use('/',          require('./routes/index'));
app.use('/customers', require('./routes/customers'));
app.use('/orders',    require('./routes/orders'));
app.use('/products',  require('./routes/products'));
app.use('/materials', require('./routes/materials'));
app.use('/suppliers', require('./routes/suppliers'));
app.use('/inventory', require('./routes/inventory'));

const PORT = 3000;
app.listen(PORT, () => {
  console.log(`Server running at http://localhost:${PORT}`);
});
