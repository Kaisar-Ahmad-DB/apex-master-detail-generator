-- Master Detail Generator: install all packages (run once in SQL Workshop > SQL Scripts)
-- Packages: MD_GENERATOR, MD_SAVE_GEN, MD_UI

CREATE OR REPLACE PACKAGE MD_GENERATOR AS

    -- Returns the single primary key column of a table
    FUNCTION GET_PK_COLUMN (P_TABLE IN VARCHAR2) RETURN VARCHAR2;

    FUNCTION GEN_SELECT (P_TABLE IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB;
    FUNCTION GEN_INSERT (P_TABLE IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB;
    FUNCTION GEN_UPDATE (P_TABLE IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB;
    FUNCTION GEN_DELETE (P_TABLE IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB;

    -- Insert + Update + Delete in one script
    FUNCTION GEN_ALL    (P_TABLE IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB;

END MD_GENERATOR;
/

CREATE OR REPLACE PACKAGE BODY MD_GENERATOR AS

    C_NL CONSTANT VARCHAR2(1) := CHR(10);

    CURSOR C_COLS (P_TAB IN VARCHAR2) IS
        SELECT C.COLUMN_NAME AS COLUMN_NAME
             , C.COLUMN_ID   AS COLUMN_ID
             , CASE WHEN I.COLUMN_NAME IS NOT NULL THEN 'Y' ELSE 'N' END AS IS_IDENTITY
          FROM USER_TAB_COLS C
          LEFT JOIN USER_TAB_IDENTITY_COLS I
            ON I.TABLE_NAME  = C.TABLE_NAME
           AND I.COLUMN_NAME = C.COLUMN_NAME
         WHERE C.TABLE_NAME     = P_TAB
           AND C.VIRTUAL_COLUMN = 'NO'
           AND C.HIDDEN_COLUMN  = 'NO'
         ORDER BY C.COLUMN_ID;

    ------------------------------------------------------------------
    FUNCTION GET_PK_COLUMN (P_TABLE IN VARCHAR2) RETURN VARCHAR2 IS
        L_PK  VARCHAR2(128);
        L_CNT NUMBER := 0;
    BEGIN
        FOR R IN (SELECT CC.COLUMN_NAME AS COLUMN_NAME
                    FROM USER_CONSTRAINTS UC
                    JOIN USER_CONS_COLUMNS CC
                      ON CC.CONSTRAINT_NAME = UC.CONSTRAINT_NAME
                   WHERE UC.TABLE_NAME      = UPPER(P_TABLE)
                     AND UC.CONSTRAINT_TYPE = 'P')
        LOOP
            L_CNT := L_CNT + 1;
            L_PK  := R.COLUMN_NAME;
        END LOOP;

        IF L_CNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'No primary key found (or table does not exist): ' || P_TABLE);
        ELSIF L_CNT > 1 THEN
            RAISE_APPLICATION_ERROR(-20002, 'Composite primary key is not supported in v1: ' || P_TABLE);
        END IF;

        RETURN L_PK;
    END GET_PK_COLUMN;

    ------------------------------------------------------------------
    FUNCTION GEN_SELECT (P_TABLE IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB IS
        L_PK    VARCHAR2(128) := GET_PK_COLUMN(P_TABLE);
        L_COLS  CLOB;
        L_INTO  CLOB;
        L_FIRST BOOLEAN := TRUE;
    BEGIN
        FOR R IN C_COLS(UPPER(P_TABLE)) LOOP
            CONTINUE WHEN R.IS_IDENTITY = 'Y'
                       OR R.COLUMN_NAME = L_PK
                       OR R.COLUMN_NAME IN ('CREATED_BY', 'CREATED_ON', 'UPDATED_BY', 'UPDATED_ON');

            L_COLS  := L_COLS || CASE WHEN L_FIRST THEN '    SELECT ' ELSE '         , ' END
                              || R.COLUMN_NAME || C_NL;
            L_INTO  := L_INTO || CASE WHEN L_FIRST THEN '      INTO ' ELSE '         , ' END
                              || ':' || P_PREFIX || R.COLUMN_NAME || C_NL;
            L_FIRST := FALSE;
        END LOOP;

        RETURN 'IF :' || P_PREFIX || L_PK || ' IS NOT NULL THEN' || C_NL
            || L_COLS || L_INTO
            || '      FROM ' || UPPER(P_TABLE) || C_NL
            || '     WHERE ' || L_PK || ' = :' || P_PREFIX || L_PK || ';' || C_NL
            || 'END IF;';
    END GEN_SELECT;

    ------------------------------------------------------------------
    FUNCTION GEN_INSERT (P_TABLE IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB IS
        L_PK    VARCHAR2(128) := GET_PK_COLUMN(P_TABLE);
        L_COLS  CLOB;
        L_VALS  CLOB;
        L_FIRST BOOLEAN := TRUE;
        L_SEP   VARCHAR2(10);
        L_VAL   VARCHAR2(200);
    BEGIN
        FOR R IN C_COLS(UPPER(P_TABLE)) LOOP
            CONTINUE WHEN R.IS_IDENTITY = 'Y' OR R.COLUMN_NAME IN ('UPDATED_BY', 'UPDATED_ON');

            L_VAL := CASE R.COLUMN_NAME
                         WHEN 'CREATED_BY' THEN ':APP_USER'
                         WHEN 'CREATED_ON' THEN 'SYSDATE'
                         ELSE ':' || P_PREFIX || R.COLUMN_NAME
                     END;
            L_SEP := CASE WHEN L_FIRST THEN '     ( ' ELSE '     , ' END;

            L_COLS  := L_COLS || L_SEP || R.COLUMN_NAME || C_NL;
            L_VALS  := L_VALS || L_SEP || L_VAL         || C_NL;
            L_FIRST := FALSE;
        END LOOP;

        RETURN 'INSERT INTO ' || UPPER(P_TABLE) || C_NL
            || L_COLS || '     )' || C_NL
            || 'VALUES' || C_NL
            || L_VALS || '     );';
    END GEN_INSERT;

    ------------------------------------------------------------------
    FUNCTION GEN_UPDATE (P_TABLE IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB IS
        L_PK    VARCHAR2(128) := GET_PK_COLUMN(P_TABLE);
        L_SQL   CLOB;
        L_MAX   NUMBER := 0;
        L_FIRST BOOLEAN := TRUE;
        L_VAL   VARCHAR2(200);
    BEGIN
        -- pass 1: longest column name (for aligned SET clause)
        FOR R IN C_COLS(UPPER(P_TABLE)) LOOP
            IF R.IS_IDENTITY = 'N'
               AND R.COLUMN_NAME <> L_PK
               AND R.COLUMN_NAME NOT IN ('CREATED_BY', 'CREATED_ON') THEN
                L_MAX := GREATEST(L_MAX, LENGTH(R.COLUMN_NAME));
            END IF;
        END LOOP;

        -- pass 2: build SET clause
        FOR R IN C_COLS(UPPER(P_TABLE)) LOOP
            CONTINUE WHEN R.IS_IDENTITY = 'Y'
                       OR R.COLUMN_NAME = L_PK
                       OR R.COLUMN_NAME IN ('CREATED_BY', 'CREATED_ON');

            L_VAL := CASE R.COLUMN_NAME
                         WHEN 'UPDATED_BY' THEN ':APP_USER'
                         WHEN 'UPDATED_ON' THEN 'SYSDATE'
                         ELSE ':' || P_PREFIX || R.COLUMN_NAME
                     END;

            L_SQL := L_SQL
                  || CASE WHEN L_FIRST THEN '   SET ' ELSE '     , ' END
                  || RPAD(R.COLUMN_NAME, L_MAX) || ' = ' || L_VAL || C_NL;
            L_FIRST := FALSE;
        END LOOP;

        RETURN 'UPDATE ' || UPPER(P_TABLE) || C_NL
            || L_SQL
            || ' WHERE ' || L_PK || ' = :' || P_PREFIX || L_PK || ';';
    END GEN_UPDATE;

    ------------------------------------------------------------------
    FUNCTION GEN_DELETE (P_TABLE IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB IS
        L_PK VARCHAR2(128) := GET_PK_COLUMN(P_TABLE);
    BEGIN
        RETURN 'DELETE FROM ' || UPPER(P_TABLE) || C_NL
            || ' WHERE ' || L_PK || ' = :' || P_PREFIX || L_PK || ';';
    END GEN_DELETE;

    ------------------------------------------------------------------
    FUNCTION GEN_ALL (P_TABLE IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB IS
    BEGIN
        RETURN '-- SELECT (load master row, e.g. Before Header process)' || C_NL || GEN_SELECT(P_TABLE, P_PREFIX) || C_NL || C_NL
            || '-- INSERT' || C_NL || GEN_INSERT(P_TABLE, P_PREFIX) || C_NL || C_NL
            || '-- UPDATE' || C_NL || GEN_UPDATE(P_TABLE, P_PREFIX) || C_NL || C_NL
            || '-- DELETE' || C_NL || GEN_DELETE(P_TABLE, P_PREFIX);
    END GEN_ALL;

END MD_GENERATOR;
/

CREATE OR REPLACE PACKAGE MD_SAVE_GEN AS

    -- FK column in the detail table that points to the master table
    FUNCTION GET_FK_COLUMN (P_MASTER IN VARCHAR2, P_DETAIL IN VARCHAR2) RETURN VARCHAR2;

    -- PL/SQL block: load detail rows into an APEX collection
    FUNCTION GEN_COLLECTION_LOAD (P_MASTER IN VARCHAR2, P_DETAIL IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB;

    -- PL/SQL block: save master + detail in one transaction
    FUNCTION GEN_SAVE            (P_MASTER IN VARCHAR2, P_DETAIL IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB;

    -- Interactive Grid source query + PL/SQL code that writes grid changes into the collection
    FUNCTION GEN_GRID            (P_MASTER IN VARCHAR2, P_DETAIL IN VARCHAR2, P_PREFIX IN VARCHAR2 DEFAULT 'P1_') RETURN CLOB;

END MD_SAVE_GEN;
/

CREATE OR REPLACE PACKAGE BODY MD_SAVE_GEN AS

    C_NL  CONSTANT VARCHAR2(1)  := CHR(10);
    C_FMT CONSTANT VARCHAR2(30) := 'YYYY-MM-DD HH24:MI:SS';

    -- Editable grid columns: no identity, no virtual, no PK, no FK, no audit columns
    CURSOR C_GRID (P_TAB IN VARCHAR2, P_PK IN VARCHAR2, P_FK IN VARCHAR2) IS
        SELECT C.COLUMN_NAME AS COLUMN_NAME
             , C.DATA_TYPE   AS DATA_TYPE
             , ROW_NUMBER() OVER (ORDER BY C.COLUMN_ID) AS POS
          FROM USER_TAB_COLS C
          LEFT JOIN USER_TAB_IDENTITY_COLS I
            ON I.TABLE_NAME  = C.TABLE_NAME
           AND I.COLUMN_NAME = C.COLUMN_NAME
         WHERE C.TABLE_NAME     = P_TAB
           AND C.VIRTUAL_COLUMN = 'NO'
           AND C.HIDDEN_COLUMN  = 'NO'
           AND I.COLUMN_NAME IS NULL
           AND C.COLUMN_NAME NOT IN (P_PK, P_FK, 'CREATED_BY', 'CREATED_ON', 'UPDATED_BY', 'UPDATED_ON')
         ORDER BY C.COLUMN_ID;

    ------------------------------------------------------------------
    FUNCTION HAS_COL (P_TAB IN VARCHAR2, P_COL IN VARCHAR2) RETURN BOOLEAN IS
        L_CNT NUMBER;
    BEGIN
        SELECT COUNT(*)
          INTO L_CNT
          FROM USER_TAB_COLS C
         WHERE C.TABLE_NAME  = P_TAB
           AND C.COLUMN_NAME = P_COL;
        RETURN L_CNT > 0;
    END HAS_COL;

    FUNCTION COLL_COL (P_POS IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN 'C' || LPAD(P_POS, 3, '0');
    END COLL_COL;

    -- collection (string) -> column value
    FUNCTION FROM_COLL (P_POS IN NUMBER, P_TYPE IN VARCHAR2) RETURN VARCHAR2 IS
        L_C VARCHAR2(20) := 'R.' || COLL_COL(P_POS);
    BEGIN
        RETURN CASE
                   WHEN P_TYPE IN ('NUMBER', 'FLOAT', 'INTEGER') THEN 'TO_NUMBER(' || L_C || ')'
                   WHEN P_TYPE = 'DATE' THEN 'TO_DATE(' || L_C || ', ''' || C_FMT || ''')'
                   ELSE L_C
               END;
    END FROM_COLL;

    -- column value -> collection (string)
    FUNCTION TO_COLL (P_COL IN VARCHAR2, P_TYPE IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
                   WHEN P_TYPE IN ('NUMBER', 'FLOAT', 'INTEGER') THEN 'TO_CHAR(R.' || P_COL || ')'
                   WHEN P_TYPE = 'DATE' THEN 'TO_CHAR(R.' || P_COL || ', ''' || C_FMT || ''')'
                   ELSE 'R.' || P_COL
               END;
    END TO_COLL;

    FUNCTION INDENT (P_TEXT IN CLOB, P_N IN NUMBER) RETURN CLOB IS
    BEGIN
        RETURN RPAD(' ', P_N) || REPLACE(P_TEXT, C_NL, C_NL || RPAD(' ', P_N));
    END INDENT;

    PROCEDURE GRID_INFO ( P_TAB IN  VARCHAR2
                        , P_PK  IN  VARCHAR2
                        , P_FK  IN  VARCHAR2
                        , P_CNT OUT NUMBER
                        , P_MAX OUT NUMBER ) IS
    BEGIN
        P_CNT := 0;
        P_MAX := 0;
        FOR G IN C_GRID(P_TAB, P_PK, P_FK) LOOP
            P_CNT := P_CNT + 1;
            P_MAX := GREATEST(P_MAX, LENGTH(G.COLUMN_NAME));
        END LOOP;

        IF P_CNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20013, 'No editable columns found in detail table: ' || P_TAB);
        ELSIF P_CNT > 50 THEN
            RAISE_APPLICATION_ERROR(-20014, 'More than 50 grid columns is not supported: ' || P_TAB);
        END IF;
    END GRID_INFO;

    ------------------------------------------------------------------
    FUNCTION GET_FK_COLUMN (P_MASTER IN VARCHAR2, P_DETAIL IN VARCHAR2) RETURN VARCHAR2 IS
        L_FK  VARCHAR2(128);
        L_CNT NUMBER := 0;
    BEGIN
        FOR R IN (SELECT CC.COLUMN_NAME AS COLUMN_NAME
                    FROM USER_CONSTRAINTS FK
                    JOIN USER_CONSTRAINTS PK
                      ON PK.CONSTRAINT_NAME = FK.R_CONSTRAINT_NAME
                    JOIN USER_CONS_COLUMNS CC
                      ON CC.CONSTRAINT_NAME = FK.CONSTRAINT_NAME
                   WHERE FK.TABLE_NAME      = UPPER(P_DETAIL)
                     AND FK.CONSTRAINT_TYPE = 'R'
                     AND PK.TABLE_NAME      = UPPER(P_MASTER))
        LOOP
            L_CNT := L_CNT + 1;
            L_FK  := R.COLUMN_NAME;
        END LOOP;

        IF L_CNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20011, 'No foreign key from ' || P_DETAIL || ' to ' || P_MASTER);
        ELSIF L_CNT > 1 THEN
            RAISE_APPLICATION_ERROR(-20012, 'Multiple or composite foreign keys are not supported in v1');
        END IF;

        RETURN L_FK;
    END GET_FK_COLUMN;

    ------------------------------------------------------------------
    FUNCTION GEN_COLLECTION_LOAD ( P_MASTER IN VARCHAR2
                                 , P_DETAIL IN VARCHAR2
                                 , P_PREFIX IN VARCHAR2 DEFAULT 'P1_' ) RETURN CLOB IS
        L_M_PK VARCHAR2(128) := MD_GENERATOR.GET_PK_COLUMN(P_MASTER);
        L_D_PK VARCHAR2(128) := MD_GENERATOR.GET_PK_COLUMN(P_DETAIL);
        L_FK   VARCHAR2(128) := GET_FK_COLUMN(P_MASTER, P_DETAIL);
        L_DET  VARCHAR2(128) := UPPER(P_DETAIL);
        L_CNT  NUMBER;
        L_MAX  NUMBER;
        L_SEL  CLOB;
        L_ADD  CLOB;
        L_SQL  CLOB;
    BEGIN
        GRID_INFO(L_DET, L_D_PK, L_FK, L_CNT, L_MAX);

        FOR G IN C_GRID(L_DET, L_D_PK, L_FK) LOOP
            L_SEL := L_SEL || RPAD(' ', 15) || ', D.' || G.COLUMN_NAME || C_NL;
            L_ADD := L_ADD || '        , ' || RPAD('P_' || COLL_COL(G.POS), 17)
                           || ' => ' || TO_COLL(G.COLUMN_NAME, G.DATA_TYPE) || C_NL;
        END LOOP;

        L_SQL := 'APEX_COLLECTION.CREATE_OR_TRUNCATE_COLLECTION(P_COLLECTION_NAME => ''' || L_DET || ''');' || C_NL || C_NL
              || 'FOR R IN (SELECT D.' || L_D_PK || C_NL
              || L_SEL
              || RPAD(' ', 10) || '  FROM ' || L_DET || ' D' || C_NL
              || RPAD(' ', 10) || ' WHERE D.' || L_FK || ' = :' || P_PREFIX || L_M_PK || C_NL
              || RPAD(' ', 10) || ' ORDER BY D.' || L_D_PK || ')' || C_NL
              || 'LOOP' || C_NL
              || '    APEX_COLLECTION.ADD_MEMBER' || C_NL
              || '        ( P_COLLECTION_NAME => ''' || L_DET || '''' || C_NL
              || '        , ' || RPAD('P_N001', 17) || ' => R.' || L_D_PK || C_NL
              || L_ADD
              || '        );' || C_NL
              || 'END LOOP;';

        RETURN 'BEGIN' || C_NL || INDENT(L_SQL, 4) || C_NL || 'END;';
    END GEN_COLLECTION_LOAD;

    ------------------------------------------------------------------
    FUNCTION GEN_GRID ( P_MASTER IN VARCHAR2
                      , P_DETAIL IN VARCHAR2
                      , P_PREFIX IN VARCHAR2 DEFAULT 'P1_' ) RETURN CLOB IS
        L_D_PK VARCHAR2(128) := MD_GENERATOR.GET_PK_COLUMN(P_DETAIL);
        L_FK   VARCHAR2(128) := GET_FK_COLUMN(P_MASTER, P_DETAIL);
        L_DET  VARCHAR2(128) := UPPER(P_DETAIL);
        L_CNT  NUMBER;
        L_MAX  NUMBER;
        L_Q    CLOB;
        L_PARM CLOB;
        L_NUM  BOOLEAN;
    BEGIN
        GRID_INFO(L_DET, L_D_PK, L_FK, L_CNT, L_MAX);

        L_Q := 'SELECT C.SEQ_ID' || C_NL
            || '     , C.N001 AS ' || L_D_PK || C_NL;

        FOR G IN C_GRID(L_DET, L_D_PK, L_FK) LOOP
            L_NUM  := G.DATA_TYPE IN ('NUMBER', 'FLOAT', 'INTEGER');
            L_Q    := L_Q || '     , '
                          || CASE WHEN L_NUM THEN 'TO_NUMBER(C.' || COLL_COL(G.POS) || ')' ELSE 'C.' || COLL_COL(G.POS) END
                          || ' AS ' || G.COLUMN_NAME || C_NL;
            L_PARM := L_PARM || '                    , ' || RPAD('P_' || COLL_COL(G.POS), 17) || ' => '
                             || CASE WHEN L_NUM THEN 'TO_CHAR(:' || G.COLUMN_NAME || ')' ELSE ':' || G.COLUMN_NAME END
                             || C_NL;
        END LOOP;

        RETURN '-- 1. Interactive Grid: Source > Type SQL Query' || C_NL
            || L_Q
            || '  FROM APEX_COLLECTIONS C' || C_NL
            || ' WHERE C.COLLECTION_NAME = ''' || L_DET || '''' || C_NL
            || ' ORDER BY C.SEQ_ID' || C_NL || C_NL
            || '-- 2. Grid columns: SEQ_ID = Primary Key (hidden), ' || L_D_PK || ' = Hidden' || C_NL
            || '-- 3. Grid process "Automatic Row Processing (DML)": Target Type = PL/SQL Code' || C_NL
            || 'BEGIN' || C_NL
            || '    CASE :APEX$ROW_STATUS' || C_NL
            || '        WHEN ''C'' THEN' || C_NL
            || '            APEX_COLLECTION.ADD_MEMBER' || C_NL
            || '                ( P_COLLECTION_NAME => ''' || L_DET || '''' || C_NL
            || L_PARM
            || '                );' || C_NL
            || '        WHEN ''U'' THEN' || C_NL
            || '            APEX_COLLECTION.UPDATE_MEMBER' || C_NL
            || '                ( P_COLLECTION_NAME => ''' || L_DET || '''' || C_NL
            || '                    , ' || RPAD('P_SEQ', 17) || ' => :SEQ_ID' || C_NL
            || '                    , ' || RPAD('P_N001', 17) || ' => :' || L_D_PK || C_NL
            || L_PARM
            || '                );' || C_NL
            || '        WHEN ''D'' THEN' || C_NL
            || '            APEX_COLLECTION.DELETE_MEMBER' || C_NL
            || '                ( P_COLLECTION_NAME => ''' || L_DET || '''' || C_NL
            || '                    , ' || RPAD('P_SEQ', 17) || ' => :SEQ_ID' || C_NL
            || '                );' || C_NL
            || '    END CASE;' || C_NL
            || 'END;';
    END GEN_GRID;

    ------------------------------------------------------------------
    FUNCTION GEN_SAVE ( P_MASTER IN VARCHAR2
                      , P_DETAIL IN VARCHAR2
                      , P_PREFIX IN VARCHAR2 DEFAULT 'P1_' ) RETURN CLOB IS
        L_M_PK VARCHAR2(128) := MD_GENERATOR.GET_PK_COLUMN(P_MASTER);
        L_D_PK VARCHAR2(128) := MD_GENERATOR.GET_PK_COLUMN(P_DETAIL);
        L_FK   VARCHAR2(128) := GET_FK_COLUMN(P_MASTER, P_DETAIL);
        L_DET  VARCHAR2(128) := UPPER(P_DETAIL);
        L_CNT  NUMBER;
        L_MAX  NUMBER;
        L_SEL  CLOB;
        L_COLS CLOB;
        L_VALS CLOB;
        L_SET  CLOB;
        L_INS  CLOB;
        L_UPD  CLOB;
        L_DEL  CLOB;
        L_LOOP CLOB;
        L_MINS CLOB;
        L_SQL  CLOB;
    BEGIN
        GRID_INFO(L_DET, L_D_PK, L_FK, L_CNT, L_MAX);
        IF HAS_COL(L_DET, 'UPDATED_BY') THEN
            L_MAX := GREATEST(L_MAX, 10);
        END IF;

        L_COLS := '     ( ' || L_FK || C_NL;
        L_VALS := '     ( L_MASTER_ID' || C_NL;

        FOR G IN C_GRID(L_DET, L_D_PK, L_FK) LOOP
            L_SEL  := L_SEL  || RPAD(' ', 15) || ', C.' || COLL_COL(G.POS) || C_NL;
            L_COLS := L_COLS || '     , ' || G.COLUMN_NAME || C_NL;
            L_VALS := L_VALS || '     , ' || FROM_COLL(G.POS, G.DATA_TYPE) || C_NL;
            L_SET  := L_SET  || CASE WHEN G.POS = 1 THEN '   SET ' ELSE '     , ' END
                             || RPAD(G.COLUMN_NAME, L_MAX) || ' = ' || FROM_COLL(G.POS, G.DATA_TYPE) || C_NL;
        END LOOP;

        -- audit columns (only if the detail table has them)
        IF HAS_COL(L_DET, 'CREATED_BY') THEN
            L_COLS := L_COLS || '     , CREATED_BY' || C_NL;
            L_VALS := L_VALS || '     , :APP_USER'  || C_NL;
        END IF;
        IF HAS_COL(L_DET, 'CREATED_ON') THEN
            L_COLS := L_COLS || '     , CREATED_ON' || C_NL;
            L_VALS := L_VALS || '     , SYSDATE'    || C_NL;
        END IF;
        IF HAS_COL(L_DET, 'UPDATED_BY') THEN
            L_SET := L_SET || '     , ' || RPAD('UPDATED_BY', L_MAX) || ' = :APP_USER' || C_NL;
        END IF;
        IF HAS_COL(L_DET, 'UPDATED_ON') THEN
            L_SET := L_SET || '     , ' || RPAD('UPDATED_ON', L_MAX) || ' = SYSDATE' || C_NL;
        END IF;

        L_INS := 'INSERT INTO ' || L_DET || C_NL
              || L_COLS || '     )' || C_NL
              || 'VALUES' || C_NL
              || L_VALS || '     );';

        L_UPD := 'UPDATE ' || L_DET || C_NL
              || L_SET
              || ' WHERE ' || L_D_PK || ' = R.N001;';

        -- detail rows removed from the grid
        L_DEL := 'FOR R IN (SELECT D.' || L_D_PK || C_NL
              || RPAD(' ', 10) || '  FROM ' || L_DET || ' D' || C_NL
              || RPAD(' ', 10) || '  LEFT JOIN APEX_COLLECTIONS C' || C_NL
              || RPAD(' ', 10) || '    ON C.COLLECTION_NAME = ''' || L_DET || '''' || C_NL
              || RPAD(' ', 10) || '   AND C.N001            = D.' || L_D_PK || C_NL
              || RPAD(' ', 10) || ' WHERE D.' || L_FK || ' = L_MASTER_ID' || C_NL
              || RPAD(' ', 10) || '   AND C.SEQ_ID IS NULL)' || C_NL
              || 'LOOP' || C_NL
              || '    DELETE FROM ' || L_DET || C_NL
              || '     WHERE ' || L_D_PK || ' = R.' || L_D_PK || ';' || C_NL
              || 'END LOOP;';

        -- detail rows to insert / update
        L_LOOP := 'FOR R IN (SELECT C.N001' || C_NL
               || L_SEL
               || RPAD(' ', 10) || '  FROM APEX_COLLECTIONS C' || C_NL
               || RPAD(' ', 10) || ' WHERE C.COLLECTION_NAME = ''' || L_DET || '''' || C_NL
               || RPAD(' ', 10) || ' ORDER BY C.SEQ_ID)' || C_NL
               || 'LOOP' || C_NL
               || '    IF R.N001 IS NULL THEN' || C_NL
               || INDENT(L_INS, 8) || C_NL
               || '    ELSE' || C_NL
               || INDENT(L_UPD, 8) || C_NL
               || '    END IF;' || C_NL
               || 'END LOOP;';

        -- master insert needs RETURNING to get the new PK
        L_MINS := RTRIM(MD_GENERATOR.GEN_INSERT(P_MASTER, P_PREFIX), ';') || C_NL
               || 'RETURNING ' || L_M_PK || ' INTO L_MASTER_ID;';

        L_SQL := 'DECLARE' || C_NL
              || '    L_MASTER_ID NUMBER := :' || P_PREFIX || L_M_PK || ';' || C_NL
              || 'BEGIN' || C_NL
              || '    -- 1. Master: insert new / update existing' || C_NL
              || '    IF L_MASTER_ID IS NULL THEN' || C_NL
              || INDENT(L_MINS, 8) || C_NL
              || '    ELSE' || C_NL
              || INDENT(MD_GENERATOR.GEN_UPDATE(P_MASTER, P_PREFIX), 8) || C_NL
              || '    END IF;' || C_NL || C_NL
              || '    -- 2. Detail: delete rows removed from the grid' || C_NL
              || INDENT(L_DEL, 4) || C_NL || C_NL
              || '    -- 3. Detail: insert new / update existing rows' || C_NL
              || INDENT(L_LOOP, 4) || C_NL || C_NL
              || '    :' || P_PREFIX || L_M_PK || ' := L_MASTER_ID;' || C_NL
              || 'END;';

        RETURN L_SQL;
    END GEN_SAVE;

END MD_SAVE_GEN;
/

CREATE OR REPLACE PACKAGE MD_UI AS

    -- P_KIND: MASTER (select/insert/update/delete), LOAD (collection load), GRID (grid query + DML), SAVE (master + detail save)
    -- Returns HTML (Copy button + escaped code)
    FUNCTION RENDER_HTML ( P_KIND   IN VARCHAR2
                         , P_MASTER IN VARCHAR2
                         , P_DETAIL IN VARCHAR2
                         , P_PREFIX IN VARCHAR2 DEFAULT 'P1_' ) RETURN CLOB;

    -- Same output, written with HTP.PRN (used by the PL/SQL Dynamic Content regions)
    PROCEDURE RENDER ( P_KIND   IN VARCHAR2
                     , P_MASTER IN VARCHAR2
                     , P_DETAIL IN VARCHAR2
                     , P_PREFIX IN VARCHAR2 DEFAULT 'P1_' );

END MD_UI;
/

CREATE OR REPLACE PACKAGE BODY MD_UI AS

    FUNCTION RENDER_HTML ( P_KIND   IN VARCHAR2
                         , P_MASTER IN VARCHAR2
                         , P_DETAIL IN VARCHAR2
                         , P_PREFIX IN VARCHAR2 DEFAULT 'P1_' ) RETURN CLOB IS
        L_CODE CLOB;
        L_HTML CLOB;
        L_POS  PLS_INTEGER := 1;
        L_LEN  PLS_INTEGER;
    BEGIN
        L_CODE := CASE P_KIND
                      WHEN 'MASTER' THEN MD_GENERATOR.GEN_ALL(P_MASTER, P_PREFIX)
                      WHEN 'LOAD'   THEN MD_SAVE_GEN.GEN_COLLECTION_LOAD(P_MASTER, P_DETAIL, P_PREFIX)
                      WHEN 'SAVE'   THEN MD_SAVE_GEN.GEN_SAVE(P_MASTER, P_DETAIL, P_PREFIX)
                      WHEN 'GRID'   THEN MD_SAVE_GEN.GEN_GRID(P_MASTER, P_DETAIL, P_PREFIX)
                  END;

        L_HTML := '<button type="button" class="t-Button t-Button--small" '
               || 'onclick="navigator.clipboard.writeText(this.nextElementSibling.innerText)">Copy code</button>'
               || '<pre style="white-space:pre;overflow-x:auto">';

        L_LEN := DBMS_LOB.GETLENGTH(L_CODE);
        WHILE L_POS <= L_LEN LOOP
            L_HTML := L_HTML || APEX_ESCAPE.HTML(DBMS_LOB.SUBSTR(L_CODE, 4000, L_POS));
            L_POS  := L_POS + 4000;
        END LOOP;

        RETURN L_HTML || '</pre>';
    EXCEPTION
        WHEN OTHERS THEN
            RETURN '<div class="t-Alert t-Alert--danger" style="padding:1rem">' || APEX_ESCAPE.HTML(SQLERRM) || '</div>';
    END RENDER_HTML;

    PROCEDURE RENDER ( P_KIND   IN VARCHAR2
                     , P_MASTER IN VARCHAR2
                     , P_DETAIL IN VARCHAR2
                     , P_PREFIX IN VARCHAR2 DEFAULT 'P1_' ) IS
        L_HTML CLOB := RENDER_HTML(P_KIND, P_MASTER, P_DETAIL, P_PREFIX);
        L_POS  PLS_INTEGER := 1;
        L_LEN  PLS_INTEGER := DBMS_LOB.GETLENGTH(L_HTML);
    BEGIN
        WHILE L_POS <= L_LEN LOOP
            HTP.PRN(DBMS_LOB.SUBSTR(L_HTML, 8000, L_POS));
            L_POS := L_POS + 8000;
        END LOOP;
    END RENDER;

END MD_UI;
/
