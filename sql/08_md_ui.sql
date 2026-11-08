CREATE OR REPLACE PACKAGE MD_UI AS

    -- P_KIND: MASTER (insert/update/delete), LOAD (collection load), SAVE (master + detail save)
    PROCEDURE RENDER ( P_KIND   IN VARCHAR2
                     , P_MASTER IN VARCHAR2
                     , P_DETAIL IN VARCHAR2
                     , P_PREFIX IN VARCHAR2 DEFAULT 'P1_' );

END MD_UI;
/

CREATE OR REPLACE PACKAGE BODY MD_UI AS

    PROCEDURE RENDER ( P_KIND   IN VARCHAR2
                     , P_MASTER IN VARCHAR2
                     , P_DETAIL IN VARCHAR2
                     , P_PREFIX IN VARCHAR2 DEFAULT 'P1_' ) IS
        L_CODE CLOB;
        L_POS  PLS_INTEGER := 1;
        L_LEN  PLS_INTEGER;
    BEGIN
        L_CODE := CASE P_KIND
                      WHEN 'MASTER' THEN MD_GENERATOR.GEN_ALL(P_MASTER, P_PREFIX)
                      WHEN 'LOAD'   THEN MD_SAVE_GEN.GEN_COLLECTION_LOAD(P_MASTER, P_DETAIL, P_PREFIX)
                      WHEN 'SAVE'   THEN MD_SAVE_GEN.GEN_SAVE(P_MASTER, P_DETAIL, P_PREFIX)
                  END;

        HTP.P('<button type="button" class="t-Button t-Button--small" '
           || 'onclick="navigator.clipboard.writeText(this.nextElementSibling.innerText)">Copy code</button>');
        HTP.PRN('<pre style="white-space:pre;overflow-x:auto">');

        L_LEN := DBMS_LOB.GETLENGTH(L_CODE);
        WHILE L_POS <= L_LEN LOOP
            HTP.PRN(APEX_ESCAPE.HTML(DBMS_LOB.SUBSTR(L_CODE, 4000, L_POS)));
            L_POS := L_POS + 4000;
        END LOOP;

        HTP.P('</pre>');
    EXCEPTION
        WHEN OTHERS THEN
            HTP.P('<div class="t-Alert t-Alert--danger" style="padding:1rem">' || APEX_ESCAPE.HTML(SQLERRM) || '</div>');
    END RENDER;

END MD_UI;
/
