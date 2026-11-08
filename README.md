# APEX Master-Detail Generator

Generate the PL/SQL for an Oracle APEX master-detail page from your own tables.

Pick a master table and a detail table, click **Generate Code**, and copy the result into your page. No more writing insert / update / delete code and the collection logic for every master-detail form by hand.

> **Status:** v1 (early release). Feedback and pull requests are welcome.

## What it generates

| # | Output | Use it for |
|---|--------|-----------|
| 1 | Master `SELECT` / `INSERT` / `UPDATE` / `DELETE` | Loading and saving the master row |
| 2 | Detail collection load | Loading the detail rows into an `APEX_COLLECTION` when the page opens |
| 3 | Interactive Grid source query + row DML | Editing the detail rows in an Interactive Grid backed by the collection |
| 4 | Master + detail save (one transaction) | The Save button: insert/update master, delete removed rows, insert/update detail rows |

What the generated code takes care of:

- Primary key, foreign key (detail to master) and identity columns are detected from the data dictionary.
- Audit columns `CREATED_BY`, `CREATED_ON`, `UPDATED_BY`, `UPDATED_ON` are set automatically (`:APP_USER`, `SYSDATE`).
- Page item names follow your prefix (for example `P2_ORDER_NO`).
- The master insert uses `RETURNING ... INTO` to get the new primary key for the detail rows.
- No `COMMIT` in the generated code, so APEX rolls back the whole page submit if anything fails.

## Screenshots

![Generator page](docs/screenshots/01-generator-page.png)
*Pick the master and detail tables, set the page item prefix, click Generate Code.*

![Master SQL output](docs/screenshots/02-master-sql.png)
*Generated master SELECT / INSERT / UPDATE / DELETE with a Copy code button.*

![Save code output](docs/screenshots/03-save-code.png)
*Generated master + detail save block.*

## Requirements

- Oracle APEX 26.2 (the app export was created on 26.2)
- A workspace whose parsing schema owns the tables you want to generate code for
- The generator reads `USER_TABLES`, `USER_TAB_COLS`, `USER_CONSTRAINTS` and `USER_CONS_COLUMNS` of that schema

## Installation

1. **(Optional) create the demo tables**

   Run `sql/01_demo_tables.sql` in **SQL Workshop > SQL Scripts**. It creates `DEMO_ORDERS` (master) and `DEMO_ORDER_ITEMS` (detail) with sample data.

2. **Install the packages**

   Run `sql/install_all.sql` in **SQL Workshop > SQL Scripts**. It creates three packages:

   | Package | Purpose |
   |---------|---------|
   | `MD_GENERATOR` | Master table code (select, insert, update, delete) |
   | `MD_SAVE_GEN` | Detail collection load, grid code, master + detail save |
   | `MD_UI` | Helper that renders the generated code with a Copy button in the app |

3. **Import the generator app**

   In **App Builder > Import**, upload `apex/master_detail_generator.sql`.

4. **Run the app** and open the home page.

## How to use it

1. Select the **Master Table**. The **Detail Table** list shows only tables that have a foreign key to the master.
2. Enter the **Page Item Prefix** of the page you are building, for example `P2_` for page 2.
3. Click **Generate Code** and copy each block into your own page.

### Building your page with the generated code

Create a blank page (for example page 2) and:

1. Add page items named `<prefix><COLUMN_NAME>` for the master columns, for example `P2_ORDER_ID` (hidden), `P2_ORDER_NO`, `P2_CUSTOMER_NAME`.
2. Add a **Before Header** process (Execute Code) and paste the master `SELECT` block (output 1) followed by the collection load (output 2).
3. Add an **Interactive Grid** region. Use the query from output 3 as its source, make `SEQ_ID` the primary key column, hide `SEQ_ID` and the detail primary key column, and enable editing. In the grid's DML process, set **Target Type** to **PL/SQL Code** and paste the `BEGIN ... END;` block from output 3.
4. Add a **Save** button and an **Execute Code** process that runs when the button is pressed. Paste output 4. Its sequence must come **after** the grid DML process.

## Example output

For `DEMO_ORDERS` with prefix `P2_` (spacing may differ slightly in your run):

```sql
-- SELECT (load master row, e.g. Before Header process)
IF :P2_ORDER_ID IS NOT NULL THEN
    SELECT ORDER_NO
         , CUSTOMER_NAME
         , ORDER_DATE
         , STATUS
      INTO :P2_ORDER_NO
         , :P2_CUSTOMER_NAME
         , :P2_ORDER_DATE
         , :P2_STATUS
      FROM DEMO_ORDERS
     WHERE ORDER_ID = :P2_ORDER_ID;
END IF;

-- INSERT
INSERT INTO DEMO_ORDERS
     ( ORDER_NO
     , CUSTOMER_NAME
     , ORDER_DATE
     , STATUS
     , CREATED_BY
     , CREATED_ON
     )
VALUES
     ( :P2_ORDER_NO
     , :P2_CUSTOMER_NAME
     , :P2_ORDER_DATE
     , :P2_STATUS
     , :APP_USER
     , SYSDATE
     );
```

Interactive Grid source for `DEMO_ORDER_ITEMS`:

```sql
SELECT C.SEQ_ID
     , C.N001 AS ITEM_ID
     , C.C001 AS ITEM_NAME
     , TO_NUMBER(C.C002) AS QTY
     , TO_NUMBER(C.C003) AS UNIT_PRICE
  FROM APEX_COLLECTIONS C
 WHERE C.COLLECTION_NAME = 'DEMO_ORDER_ITEMS'
 ORDER BY C.SEQ_ID
```

## Limitations (v1)

- Master and detail tables need a **single-column primary key**. Composite keys raise an error.
- The detail table needs exactly **one foreign key** to the master table.
- Up to **50 editable columns** in the detail grid.
- `DATE` columns are held in the collection as text (`YYYY-MM-DD HH24:MI:SS`) and show as text in the grid.
- `CLOB` and `BLOB` columns are not supported in the detail grid.
- Audit columns are only handled when they are named `CREATED_BY`, `CREATED_ON`, `UPDATED_BY`, `UPDATED_ON`.
- The generated code is a starting point. Review it before using it in production.

## Repository structure

```
apex-master-detail-generator/
├── README.md
├── LICENSE
├── sql/
│   ├── 01_demo_tables.sql      demo tables and data (optional)
│   └── install_all.sql         MD_GENERATOR, MD_SAVE_GEN, MD_UI
├── apex/
│   └── master_detail_generator.sql   generator app export
└── docs/
    └── screenshots/
```

## Roadmap

- Support composite primary keys
- Generate validations
- Generate code for a Form region plus Interactive Grid page with native processes
- Date and timestamp handling in the grid

## Contributing

Issues and pull requests are welcome. If a table shape breaks the generator, please open an issue with the table DDL.

## License

MIT, see `LICENSE`.

## Author

**Your Name**, Oracle APEX and PL/SQL developer
[LinkedIn](https://www.linkedin.com/in/your-profile) · [GitHub](https://github.com/your-username)
