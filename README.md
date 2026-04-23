# Restaurant Management System

A full-stack restaurant chain management system built with **PostgreSQL 15** and **Node.js + Express**, demonstrating real-world database design with constraints, triggers, stored procedures, and automated business logic.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Database | PostgreSQL 15 |
| Backend | Node.js + Express.js |
| Templating | EJS |
| DB Driver | node-postgres (pg) |
| Dev Tools | pgAdmin 4, Git |

---

## Database Design

- **15 tables** covering the full restaurant management domain
- **18 indexes** for query performance
- **5 triggers** automating business rules
- **1 stored procedure** (`sp_place_order`) handling the full order creation flow
- **3 helper functions** for availability checking and batch status refresh

### Entity Groups

| Group | Tables |
|-------|--------|
| Core | Restaurant, Menu, Customer, Delivery_Platform |
| Procurement | Supplier, Material, Purchase, Purchase_Item, Inventory_Batch |
| Menu | Product, Offers, Product_Material |
| Orders | Order, Order_Item, Membership_Card |

### Triggers

| Trigger | Event | Effect |
|---------|-------|--------|
| `trg_deduct_inventory` | AFTER UPDATE on Order (pending → confirmed) | FIFO deduction across Inventory_Batch |
| `trg_offers_on_batch` | AFTER INSERT/UPDATE on Inventory_Batch | Refreshes per-branch product availability |
| `trg_auto_batch_status` | BEFORE INSERT/UPDATE on Inventory_Batch | Auto-sets: depleted / near_expiry / pending_disposal / available |
| `trg_points_on_complete` | AFTER UPDATE on Order (→ completed) | Updates Membership_Card.points_balance |
| `trg_delivery_needs_platform` | BEFORE INSERT on Order | Blocks delivery orders without a platform_id |

---

## Prerequisites

- [PostgreSQL 15](https://www.postgresql.org/download/)
- [Node.js v18+](https://nodejs.org/)
- [pgAdmin 4](https://www.pgadmin.org/) (optional, for database inspection)

---

## Setup Instructions

### 1. Clone the repository

```bash
git clone https://github.com/YOUR_USERNAME/restaurant-management-system.git
cd restaurant-management-system
```

### 2. Create the database

Open a terminal and run:

```bash
psql -U postgres -c "CREATE DATABASE restaurant_management;"
psql -U postgres -c "CREATE USER restaurant_admin WITH PASSWORD 'yourpassword';"
psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE restaurant_management TO restaurant_admin;"
```

Then connect and grant schema privileges:

```bash
psql -U postgres -d restaurant_management -c "GRANT ALL ON SCHEMA public TO restaurant_admin;"
```

### 3. Import the schema and seed data

```bash
psql -U postgres -d restaurant_management -f schema_final.sql
psql -U postgres -d restaurant_management -f db_with_data.sql
```

### 4. Configure database connection

Open `db.js` and update the credentials:

```javascript
const pool = new Pool({
  host:     'localhost',
  port:     5432,
  database: 'restaurant_management',
  user:     'postgres',
  password: 'yourpassword',
});
```

### 5. Install dependencies

```bash
npm install
```

### 6. Start the server

```bash
node index.js
```

Visit **http://localhost:3000** in your browser.

---

## Application Features

| Page | URL | Features |
|------|-----|---------|
| Dashboard | `/` | Live counts: customers, orders, products, batches |
| Products | `/products` | Add / edit / list / unlist products; per-branch availability |
| Inventory | `/inventory` | Stock levels, batch status, expiry warnings |
| Purchases | `/inventory/purchases` | Create purchase orders; auto-generates inventory batches on delivery |
| Batches | `/inventory/batches` | Per-batch status; dispose expired batches |
| Orders | `/orders` | Place orders via `sp_place_order`; full status lifecycle |
| Customers | `/customers` | Add customers; issue and manage membership cards |
| Suppliers | `/suppliers` | Add / edit suppliers |
| Materials | `/materials` | Add / edit raw materials |

---

## Demo Flow

Follow this sequence to demonstrate the full system:

1. **Add supplier & material** — Suppliers → Add Supplier → Materials → Add Material
2. **Create purchase order** — Inventory → Purchases → New Purchase (status: Delivered) → Inventory_Batch auto-generated
3. **Add product to menu** — Products → Add Product → appears in both branches automatically
4. **Add customer + membership card** — Customers → Add Customer (tick "Issue a membership card")
5. **Place order with points** — Orders → New Order → select customer with card → enter points to use → `sp_place_order` executes
6. **Confirm order → inventory deducted** — Order detail → Mark as confirmed → `trg_deduct_inventory` fires (FIFO)
7. **Complete order → points settled** — Mark as completed → `trg_points_on_complete` fires → card balance updated

---

## Key Business Rules

- `order_type` is enforced as `dine_in | takeout | delivery` via CHECK constraint
- Delivery orders **must** specify a `platform_id` — enforced by `trg_delivery_needs_platform`
- Inventory is deducted using **FIFO** (earliest expiry first) when an order is confirmed
- Per-branch product availability (`Offers.availability_status`) is automatically recalculated after every inventory change
- Membership card points: **10 pts = €1 discount**, capped at 20% of order total
- Points are earned at checkout (`floor(final_amount / 10)`) and settled when the order completes

---

## Project Structure

```
restaurant_app/
├── index.js              # Express entry point
├── db.js                 # PostgreSQL connection pool
├── schema_final.sql      # Database schema (tables, triggers, procedures)
├── db_with_data.sql      # Full dump with seed data
├── routes/
│   ├── index.js          # Dashboard
│   ├── customers.js      # Customer + membership card CRUD
│   ├── orders.js         # Order lifecycle
│   ├── products.js       # Product management
│   ├── inventory.js      # Inventory + purchase orders
│   ├── suppliers.js      # Supplier CRUD
│   └── materials.js      # Material CRUD
├── views/
│   ├── partials/         # header.ejs, footer.ejs
│   ├── customers/        # index, show, new, edit
│   ├── orders/           # index, show, new
│   ├── products/         # index, show, new, edit
│   ├── inventory/        # index, purchases, batches, purchase_show, purchases_new
│   ├── suppliers/        # index, new, edit
│   └── materials/        # index, new, edit
└── public/
    └── style.css
```

---

## Entity Relationship Diagram

See the ERD in the project presentation (`restaurant_management_presentation.pptx`), Slide 3.

---

## License

Academic project — Database Systems, 2026.
