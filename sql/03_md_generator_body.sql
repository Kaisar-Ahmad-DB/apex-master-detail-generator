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
        RETURN '-- INSERT' || C_NL || GEN_INSERT(P_TABLE, P_PREFIX) || C_NL || C_NL
            || '-- UPDATE' || C_NL || GEN_UPDATE(P_TABLE, P_PREFIX) || C_NL || C_NL
            || '-- DELETE' || C_NL || GEN_DELETE(P_TABLE, P_PREFIX);
    END GEN_ALL;

END MD_GENERATOR;
/
