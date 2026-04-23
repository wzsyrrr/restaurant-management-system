const { Pool } = require('pg');

const pool = new Pool({
  host:     'localhost',
  port:     5432,
  database: 'restaurant_management',
  user:     'postgres',
  password: '991204',   // 填你的 postgres 密码，没有就留空
});

module.exports = pool;
