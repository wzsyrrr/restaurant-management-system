# Restaurant Management System

A full-stack restaurant chain management system built with **PostgreSQL 15**, **Node.js**, **Express**, and **EJS**.  
This project focuses on the **database core** of the application, including schema design, integrity constraints, triggers, and stored procedures for automated business logic.

---

## 1. Project Overview

This system supports the full workflow of a restaurant chain:

- shared menu across branches
- branch-level product availability
- procurement and batch-based inventory management
- dine-in, takeout, and delivery orders
- membership cards and loyalty points
- trigger-driven automation inside PostgreSQL

The main goal of the project is to show how important business rules can be enforced **inside the database layer**, not only in application code.

---

## 2. Tech Stack

| Layer | Technology |
|---|---|
| Database | PostgreSQL 15 |
| Backend | Node.js + Express.js |
| Frontend templating | EJS |
| DB Driver | node-postgres (`pg`) |
| Styling | CSS |
| Tools | pgAdmin 4, Git |

---

## 3. Main Database Features

- **15 tables** covering restaurant, menu, products, procurement, inventory, orders, delivery, customers, and membership
- **Relationship tables** such as `Offers` and `Product_Material`
- **CHECK constraints** for status fields and order types
- **Foreign keys** for referential integrity
- **Stored procedure** `sp_place_order(...)` for order creation
- **Trigger chain** for:
  - delivery validation
  - FIFO inventory deduction
  - batch status refresh
  - branch-level offer refresh
  - membership point update

---

## 4. Database Design Summary

### Core design decisions

#### Shared menu, branch-specific availability
All branches share the same `Menu`, but product availability is stored in `Offers(restaurant_id, product_id, availability_status)`.  
This separates:
- global menu definition
- branch-level sellability

#### Batch-based inventory
Stock is not stored directly on `Material`.  
Instead, inventory is represented through `Inventory_Batch`, which stores:
- `inbound_time`
- `remaining_quantity`
- `expiry_time`
- `batch_status`

This supports:
- FIFO deduction
- expiry-aware stock consumption
- automatic batch status updates

#### Recipe-based material consumption
`Product_Material(product_id, material_id, required_quantity)` records how much of each material is needed for each product.  
This allows the database to deduct ingredients automatically when an order is confirmed.

---

## 5. Trigger and Procedure Logic

### Stored procedure
- `sp_place_order(...)`
  - creates an order
  - inserts order items
  - computes `total_amount`, `deduction_amount`, `final_amount`, and `points_earned`

### Triggers
- `trg_delivery_needs_platform`
  - blocks delivery orders without a `platform_id`

- `trg_deduct_inventory`
  - runs when an order changes from `pending` to `confirmed`
  - deducts inventory from `Inventory_Batch` using FIFO logic

- `trg_auto_batch_status`
  - refreshes batch status based on quantity and expiry
  - statuses include `available`, `near_expiry`, `pending_disposal`, and `depleted`

- `trg_offers_on_order`
- `trg_offers_on_batch`
  - recompute branch-level product availability in `Offers`

- `trg_points_on_complete`
  - updates membership card points when an order reaches `completed`

---

## 6. Prerequisites

Please install the following before running the system:

- PostgreSQL 15
- Node.js 18+
- pgAdmin 4 (optional, but useful for database inspection)

---

## 7. How to Run the System

### Step 1: Clone the repository

```bash
git clone https://github.com/wzsyrrr/restaurant-management-system.git
cd restaurant-management-system
```

### Step 2: Create the database

```bash
psql -U postgres -c "CREATE DATABASE restaurant_management;"
```

### Step 3: Import the database

Use **only one** of the following options:

#### Option A: Import the full database (recommended)
This includes both schema and sample data.

```bash
psql -U postgres -d restaurant_management -f db_with_data.sql
```

#### Option B: Import schema only
If you only want the structure without data:

```bash
psql -U postgres -d restaurant_management -f schema_final.sql
```

### Step 4: Configure database connection

Open `db.js` and update the connection settings:

```js
const pool = new Pool({
  host: 'localhost',
  port: 5432,
  database: 'restaurant_management',
  user: 'postgres',
  password: 'YOUR_POSTGRES_PASSWORD'
});
```

### Step 5: Install dependencies

```bash
npm install
```

### Step 6: Start the application

```bash
node index.js
```

Then open:

```text
http://localhost:3000
```

---

## 8. Application Pages

| Page | URL | Purpose |
|---|---|---|
| Dashboard | `/` | View summary counts |
| Products | `/products` | Add, edit, list, and unlist products |
| Inventory | `/inventory` | View stock levels and batch status |
| Purchases | `/inventory/purchases` | Create purchase orders |
| Batches | `/inventory/batches` | Inspect and manage inventory batches |
| Orders | `/orders` | Place and update orders |
| Customers | `/customers` | Manage customers and membership cards |
| Suppliers | `/suppliers` | Manage suppliers |
| Materials | `/materials` | Manage raw materials |

---

## 9. Demo Flow

A good demo sequence is:

1. Add a supplier and a material
2. Create a purchase order and generate inventory batches
3. Add a product and define its required materials
4. Add a customer and issue a membership card
5. Place a new order with `sp_place_order(...)`
6. Confirm the order and show FIFO inventory deduction
7. Show automatic batch status and offer refresh
8. Complete the order and show membership point update

---

## 10. Key Business Rules

- `order_type` must be one of:
  - `dine_in`
  - `takeout`
  - `delivery`

- Delivery orders must specify a `platform_id`

- Inventory is deducted using FIFO when an order is confirmed

- Product availability is branch-specific and stored in `Offers`

- Membership points are updated only when the order is completed

---

## 11. Project Structure

```text
restaurant-management-system/
├── index.js
├── db.js
├── package.json
├── schema_final.sql
├── db_with_data.sql
├── routes/
│   ├── index.js
│   ├── customers.js
│   ├── orders.js
│   ├── products.js
│   ├── inventory.js
│   ├── suppliers.js
│   └── materials.js
├── views/
│   ├── partials/
│   ├── customers/
│   ├── orders/
│   ├── products/
│   ├── inventory/
│   ├── suppliers/
│   └── materials/
└── public/
    └── style.css
```

---

## 12. Notes

- `db_with_data.sql` is the easiest way to reproduce the complete project state.
- `schema_final.sql` is useful if you only want the schema without seed data.
- For security, do **not** commit real database passwords in `db.js`.
- It is also recommended to remove `node_modules/`, `.DS_Store`, and other local files from the repository and add them to `.gitignore`.

---

## 13. License

Academic project — Database Systems, 2026.
