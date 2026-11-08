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
