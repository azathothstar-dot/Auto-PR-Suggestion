REPORT auto_pr_suggest.

TABLES: eban.

CONSTANTS:
  c_werks        TYPE werks_d VALUE '1059',
  c_lgort        TYPE lgort_d VALUE 'AM05',
  c_start_date   TYPE dats    VALUE '20190101',
  c_stale_days   TYPE i       VALUE 365,
  c_recent_days  TYPE i       VALUE 90.

TYPES: BEGIN OF ty_pr_item,
         matnr TYPE matnr,
         menge TYPE menge_d,
         erdat TYPE dats,
         afnam TYPE afnam,
       END OF ty_pr_item.

TYPES: BEGIN OF ty_agg,
         matnr      TYPE matnr,
         maktx      TYPE maktx,
         pr_count   TYPE i,
         total_qty  TYPE menge_d,
         last_date  TYPE dats,
         last_qty   TYPE menge_d,
         sugg_qty   TYPE menge_d,
         last_req   TYPE afnam,
         days_since TYPE i,
         category   TYPE char50,
         last_price TYPE ekpo-netpr,
         currency   TYPE waers,
       END OF ty_agg.

TYPES: BEGIN OF ty_mail,
         email TYPE ad_smtpadr,
       END OF ty_mail.

DATA: lv_from       TYPE dats,
      lt_pr         TYPE TABLE OF ty_pr_item,
      lt_agg        TYPE SORTED TABLE OF ty_agg WITH UNIQUE KEY matnr,
      lt_rep        TYPE STANDARD TABLE OF ty_agg WITH EMPTY KEY,
      lt_one        TYPE STANDARD TABLE OF ty_agg WITH EMPTY KEY,
      lt_blocked    TYPE STANDARD TABLE OF ty_agg WITH EMPTY KEY,
      lt_open_pr    TYPE HASHED TABLE OF matnr WITH UNIQUE KEY table_line,
      lt_open_po    TYPE HASHED TABLE OF matnr WITH UNIQUE KEY table_line,
      lt_matnr      TYPE HASHED TABLE OF matnr WITH UNIQUE KEY table_line,
      lv_avg        TYPE f,
      lv_int        TYPE i,
      lv_xstr       TYPE xstring,
      lt_bin        TYPE solix_tab,
      lv_size       TYPE so_obj_len,
      lv_subject    TYPE so_obj_des,
      lt_body       TYPE bcsy_text,
      lt_xml        TYPE STANDARD TABLE OF string WITH EMPTY KEY,
      ls_row        TYPE ty_agg,
      lt_recipients TYPE TABLE OF ty_mail.

TRY.
  SELECT email
    FROM zmm_pr_suggest_mail
    INTO TABLE @lt_recipients
   WHERE active = 'X'.
CATCH cx_sy_dynamic_call_error
      cx_sy_open_sql_db.
  APPEND VALUE ty_mail( email = 'mahadev.lohar@tatamotors.com' ) TO lt_recipients.
  APPEND VALUE ty_mail( email = 'sanjay.dhake@tatamotors.com'  ) TO lt_recipients.
ENDTRY.

IF lt_recipients IS INITIAL.
  APPEND VALUE ty_mail( email = 'mahadev.lohar@tatamotors.com' ) TO lt_recipients.
  APPEND VALUE ty_mail( email = 'sanjay.dhake@tatamotors.com'  ) TO lt_recipients.
ENDIF.

lv_from = c_start_date.

SELECT matnr, menge, erdat, afnam
  FROM eban
  INTO TABLE @lt_pr
 WHERE werks = @c_werks
   AND lgort = @c_lgort
   AND erdat BETWEEN @lv_from AND @sy-datum
   AND loekz = ''
   AND matnr <> ''.

DEFINE _xml.
  APPEND &1 TO lt_xml.
END-OF-DEFINITION.

FORM send_alert USING iv_subject TYPE so_obj_des
                      it_body    TYPE bcsy_text.
  TRY.
    DATA(lo_send) = cl_bcs=>create_persistent( ).
    DATA(lo_doc)  = cl_document_bcs=>create_document(
                      i_type    = 'RAW'
                      i_text    = it_body
                      i_subject = iv_subject ).
    lo_send->set_document( lo_doc ).
    LOOP AT lt_recipients INTO DATA(ls_rec).
      lo_send->add_recipient(
        cl_cam_address_bcs=>create_internet_address( ls_rec-email ) ).
    ENDLOOP.
    lo_send->set_send_immediately( abap_true ).
    lo_send->send( i_with_error_screen = abap_false ).
    COMMIT WORK.
  CATCH cx_send_req_bcs INTO DATA(lx_bcs_alert).
    DATA: lv_alert_handle TYPE balloghndl.
    CALL FUNCTION 'BAL_LOG_CREATE'
      EXPORTING
        i_s_log = VALUE bal_s_log(
                    object    = 'ZMM_PR_SUGGEST'
                    subobject = 'ALERT'
                    aluser    = sy-uname
                    alprog    = sy-repid )
      IMPORTING
        e_log_handle = lv_alert_handle.
    CALL FUNCTION 'BAL_LOG_MSG_ADD_FREE_TEXT'
      EXPORTING
        i_log_handle = lv_alert_handle
        i_msgty      = 'E'
        i_text       = |Alert email send failed: { lx_bcs_alert->get_text( ) }|.
    CALL FUNCTION 'BAL_DB_SAVE'
      EXPORTING
        i_log_handle = lv_alert_handle.
    COMMIT WORK.
  ENDTRY.
ENDFORM.

IF lt_pr IS INITIAL.
  DATA: lt_body0 TYPE bcsy_text,
        lv_sub0  TYPE so_obj_des.
  lv_sub0 = |Auto PR Suggest - NO DATA (From { c_start_date+6(2) }.{ c_start_date+4(2) }.{ c_start_date+0(4) })|.
  APPEND |No PR items found for WERKS={ c_werks }, LGORT={ c_lgort }.| TO lt_body0.
  APPEND |Filters: loekz='', all item categories, all purchasing groups.| TO lt_body0.
  APPEND |Time Window: { lv_from+6(2) }.{ lv_from+4(2) }.{ lv_from+0(4) } to { sy-datum+6(2) }.{ sy-datum+4(2) }.{ sy-datum+0(4) }| TO lt_body0.
  PERFORM send_alert USING lv_sub0 lt_body0.
  RETURN.
ENDIF.

SORT lt_pr BY matnr erdat.

LOOP AT lt_pr INTO DATA(ls_pr).
  READ TABLE lt_agg ASSIGNING FIELD-SYMBOL(<a>) WITH KEY matnr = ls_pr-matnr.
  IF sy-subrc <> 0.
    INSERT VALUE ty_agg(
      matnr      = ls_pr-matnr
      maktx      = ''
      pr_count   = 1
      total_qty  = ls_pr-menge
      last_date  = ls_pr-erdat
      last_qty   = ls_pr-menge
      sugg_qty   = 0
      last_req   = ls_pr-afnam
      days_since = 0
      category   = ''
      last_price = 0
      currency   = ''
    ) INTO TABLE lt_agg.
  ELSE.
    <a>-pr_count  += 1.
    <a>-total_qty += ls_pr-menge.
    IF ls_pr-erdat >= <a>-last_date.
      <a>-last_date = ls_pr-erdat.
      <a>-last_qty  = ls_pr-menge.
      <a>-last_req  = ls_pr-afnam.
    ENDIF.
  ENDIF.
ENDLOOP.

LOOP AT lt_agg INTO DATA(tmp).
  INSERT tmp-matnr INTO TABLE lt_matnr.
ENDLOOP.

IF lt_matnr IS NOT INITIAL.
  DATA lt_makt TYPE HASHED TABLE OF makt WITH UNIQUE KEY matnr.
  SELECT matnr, maktx
    FROM makt
    INTO TABLE @lt_makt
   WHERE matnr IN @lt_matnr
     AND spras = @sy-langu.
  LOOP AT lt_agg ASSIGNING <a>.
    READ TABLE lt_makt ASSIGNING FIELD-SYMBOL(<makt>) WITH KEY matnr = <a>-matnr.
    IF sy-subrc = 0.
      <a>-maktx = <makt>-maktx.
    ENDIF.
  ENDLOOP.
ENDIF.

IF lt_matnr IS NOT INITIAL.
  TYPES: BEGIN OF ty_price,
           matnr TYPE matnr,
           netpr TYPE ekpo-netpr,
           waers TYPE waers,
           bedat TYPE ekko-bedat,
         END OF ty_price.

  DATA lt_prices_raw TYPE TABLE OF ty_price.
  DATA lt_prices     TYPE HASHED TABLE OF ty_price WITH UNIQUE KEY matnr.

  SELECT ekpo~matnr, ekpo~netpr, ekko~waers, ekko~bedat
    FROM ekpo
    INNER JOIN ekko ON ekpo~ebeln = ekko~ebeln
    INTO TABLE @lt_prices_raw
   WHERE ekpo~matnr IN @lt_matnr
     AND ekpo~werks  = @c_werks
     AND ekpo~lgort  = @c_lgort
     AND ekpo~loekz  = ''
     AND ekpo~netpr  > 0.

  SORT lt_prices_raw BY matnr ASCENDING bedat DESCENDING.
  LOOP AT lt_prices_raw INTO DATA(ls_price_raw).
    INSERT ls_price_raw INTO TABLE lt_prices.
  ENDLOOP.

  LOOP AT lt_agg ASSIGNING <a>.
    READ TABLE lt_prices ASSIGNING FIELD-SYMBOL(<price>) WITH KEY matnr = <a>-matnr.
    IF sy-subrc = 0.
      <a>-last_price = <price>-netpr.
      <a>-currency   = <price>-waers.
    ENDIF.
  ENDLOOP.
ENDIF.

LOOP AT lt_agg ASSIGNING <a>.
  <a>-days_since = sy-datum - <a>-last_date.

  IF <a>-pr_count > 0.
    lv_avg = <a>-total_qty / <a>-pr_count.
    lv_int = lv_avg.
    IF lv_avg > lv_int. lv_int = lv_int + 1. ENDIF.
  ENDIF.

  IF <a>-days_since <= c_recent_days.
    IF <a>-pr_count >= 2.
      <a>-category = 'Repeated - Recently Ordered'.
    ELSE.
      <a>-category = 'Recently Ordered - Not Required Now'.
    ENDIF.
    <a>-sugg_qty = 0.
  ELSE.
    IF <a>-pr_count >= 2.
      <a>-category = 'REPEATED'.
      <a>-sugg_qty = lv_int.
    ELSE.
      IF <a>-days_since > c_stale_days.
        <a>-category = 'Not Called for Long Time'.
      ELSE.
        <a>-category = 'Recent'.
      ENDIF.
      <a>-sugg_qty = <a>-last_qty.
    ENDIF.
  ENDIF.
ENDLOOP.

SELECT DISTINCT matnr
  FROM eban
  INTO TABLE @lt_open_pr
 WHERE werks = @c_werks
   AND lgort = @c_lgort
   AND loekz = ''
   AND ebeln = ''
   AND matnr <> ''.

SELECT DISTINCT ekpo~matnr
  FROM ekpo
  INNER JOIN ekko ON ekpo~ebeln = ekko~ebeln
  INTO TABLE @lt_open_po
 WHERE ekpo~werks = @c_werks
   AND ekpo~lgort = @c_lgort
   AND ekpo~loekz = ''
   AND ekpo~elikz = ''
   AND ekpo~menge > ekpo~wemng
   AND ekpo~matnr <> ''.

LOOP AT lt_agg ASSIGNING <a>.
  READ TABLE lt_open_pr WITH KEY table_line = <a>-matnr TRANSPORTING NO FIELDS.
  IF sy-subrc = 0.
    <a>-category = 'Open PR Exists - No Action'.
    <a>-sugg_qty = 0.
    CONTINUE.
  ENDIF.
  READ TABLE lt_open_po WITH KEY table_line = <a>-matnr TRANSPORTING NO FIELDS.
  IF sy-subrc = 0.
    <a>-category = 'Open PO Exists - No Action'.
    <a>-sugg_qty = 0.
    CONTINUE.
  ENDIF.
ENDLOOP.

LOOP AT lt_agg INTO ls_row.
  CASE ls_row-category.
    WHEN 'REPEATED'.
      APPEND ls_row TO lt_rep.
    WHEN 'Repeated - Recently Ordered'
       OR 'Recently Ordered - Not Required Now'
       OR 'Open PR Exists - No Action'
       OR 'Open PO Exists - No Action'.
      APPEND ls_row TO lt_blocked.
    WHEN OTHERS.
      APPEND ls_row TO lt_one.
  ENDCASE.
ENDLOOP.

SORT lt_rep     BY pr_count DESCENDING last_date DESCENDING.
SORT lt_one     BY category ASCENDING  last_date DESCENDING.
SORT lt_blocked BY pr_count DESCENDING last_date DESCENDING.

DATA: lv_val TYPE string,
      lv_row TYPE i.

FORM xml_val USING iv_raw TYPE string CHANGING cv_out TYPE string.
  cv_out = iv_raw.
  REPLACE ALL OCCURRENCES OF '&' IN cv_out WITH '&amp;'.
  REPLACE ALL OCCURRENCES OF '<' IN cv_out WITH '&lt;'.
  REPLACE ALL OCCURRENCES OF '>' IN cv_out WITH '&gt;'.
  REPLACE ALL OCCURRENCES OF '"' IN cv_out WITH '&quot;'.
ENDFORM.

_xml '<?xml version="1.0" encoding="UTF-8"?>'.
_xml '<?mso-application progid="Excel.Sheet"?>'.
_xml '<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"'.
_xml ' xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet"'.
_xml ' xmlns:x="urn:schemas-microsoft-com:office:excel">'.
_xml '<Styles>'.
_xml ' <Style ss:ID="header">'.
_xml '  <Font ss:Bold="1" ss:Size="10" ss:Color="#FFFFFF"/>'.
_xml '  <Interior ss:Color="#1F4E79" ss:Pattern="Solid"/>'.
_xml '  <Alignment ss:Horizontal="Center" ss:Vertical="Center" ss:WrapText="1"/>'.
_xml '  <Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#FFFFFF"/></Borders>'.
_xml ' </Style>'.
_xml ' <Style ss:ID="data">'.
_xml '  <Font ss:Size="9"/><Alignment ss:Vertical="Center"/>'.
_xml '  <Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#D0D0D0"/></Borders>'.
_xml ' </Style>'.
_xml ' <Style ss:ID="dataalt">'.
_xml '  <Font ss:Size="9"/><Interior ss:Color="#EBF3FB" ss:Pattern="Solid"/>'.
_xml '  <Alignment ss:Vertical="Center"/>'.
_xml '  <Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#D0D0D0"/></Borders>'.
_xml ' </Style>'.
_xml ' <Style ss:ID="num">'.
_xml '  <Font ss:Size="9"/><Alignment ss:Horizontal="Right" ss:Vertical="Center"/>'.
_xml '  <NumberFormat ss:Format="#,##0.00"/>'.
_xml '  <Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#D0D0D0"/></Borders>'.
_xml ' </Style>'.
_xml ' <Style ss:ID="numalt">'.
_xml '  <Font ss:Size="9"/><Interior ss:Color="#EBF3FB" ss:Pattern="Solid"/>'.
_xml '  <Alignment ss:Horizontal="Right" ss:Vertical="Center"/>'.
_xml '  <NumberFormat ss:Format="#,##0.00"/>'.
_xml '  <Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#D0D0D0"/></Borders>'.
_xml ' </Style>'.
_xml ' <Style ss:ID="date">'.
_xml '  <Font ss:Size="9"/><Alignment ss:Horizontal="Center" ss:Vertical="Center"/>'.
_xml '  <Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#D0D0D0"/></Borders>'.
_xml ' </Style>'.
_xml ' <Style ss:ID="title">'.
_xml '  <Font ss:Bold="1" ss:Size="12" ss:Color="#1F4E79"/>'.
_xml ' </Style>'.
_xml '</Styles>'.

FORM write_row1 USING is_row TYPE ty_agg iv_rownum TYPE i.
  DATA: lv_s  TYPE string,
        lv_sn TYPE string,
        lv_v  TYPE string.
  lv_s  = COND #( WHEN iv_rownum MOD 2 = 0 THEN 'data'  ELSE 'dataalt' ).
  lv_sn = COND #( WHEN iv_rownum MOD 2 = 0 THEN 'num'   ELSE 'numalt'  ).
  APPEND '<Row ss:Height="18">' TO lt_xml.
  PERFORM xml_val USING is_row-matnr CHANGING lv_v.
  APPEND |<Cell ss:StyleID="{ lv_s }"><Data ss:Type="String">{ lv_v }</Data></Cell>| TO lt_xml.
  PERFORM xml_val USING is_row-maktx CHANGING lv_v.
  APPEND |<Cell ss:StyleID="{ lv_s }"><Data ss:Type="String">{ lv_v }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="{ lv_sn }"><Data ss:Type="Number">{ is_row-pr_count }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="{ lv_sn }"><Data ss:Type="Number">{ is_row-total_qty }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="date"><Data ss:Type="String">{ is_row-last_date+6(2) }.{ is_row-last_date+4(2) }.{ is_row-last_date+0(4) }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="{ lv_sn }"><Data ss:Type="Number">{ is_row-last_qty }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="{ lv_sn }"><Data ss:Type="Number">{ is_row-sugg_qty }</Data></Cell>| TO lt_xml.
  PERFORM xml_val USING is_row-last_req CHANGING lv_v.
  APPEND |<Cell ss:StyleID="{ lv_s }"><Data ss:Type="String">{ lv_v }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="{ lv_sn }"><Data ss:Type="Number">{ is_row-days_since }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="{ lv_sn }"><Data ss:Type="Number">{ is_row-last_price }</Data></Cell>| TO lt_xml.
  PERFORM xml_val USING is_row-currency CHANGING lv_v.
  APPEND |<Cell ss:StyleID="{ lv_s }"><Data ss:Type="String">{ lv_v }</Data></Cell>| TO lt_xml.
  APPEND '</Row>' TO lt_xml.
ENDFORM.

FORM write_row2 USING is_row TYPE ty_agg iv_rownum TYPE i.
  DATA: lv_s  TYPE string,
        lv_sn TYPE string,
        lv_v  TYPE string.
  lv_s  = COND #( WHEN iv_rownum MOD 2 = 0 THEN 'data'  ELSE 'dataalt' ).
  lv_sn = COND #( WHEN iv_rownum MOD 2 = 0 THEN 'num'   ELSE 'numalt'  ).
  APPEND '<Row ss:Height="18">' TO lt_xml.
  PERFORM xml_val USING is_row-category CHANGING lv_v.
  APPEND |<Cell ss:StyleID="{ lv_s }"><Data ss:Type="String">{ lv_v }</Data></Cell>| TO lt_xml.
  PERFORM xml_val USING is_row-matnr CHANGING lv_v.
  APPEND |<Cell ss:StyleID="{ lv_s }"><Data ss:Type="String">{ lv_v }</Data></Cell>| TO lt_xml.
  PERFORM xml_val USING is_row-maktx CHANGING lv_v.
  APPEND |<Cell ss:StyleID="{ lv_s }"><Data ss:Type="String">{ lv_v }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="{ lv_sn }"><Data ss:Type="Number">{ is_row-pr_count }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="{ lv_sn }"><Data ss:Type="Number">{ is_row-total_qty }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="date"><Data ss:Type="String">{ is_row-last_date+6(2) }.{ is_row-last_date+4(2) }.{ is_row-last_date+0(4) }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="{ lv_sn }"><Data ss:Type="Number">{ is_row-last_qty }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="{ lv_sn }"><Data ss:Type="Number">{ is_row-sugg_qty }</Data></Cell>| TO lt_xml.
  PERFORM xml_val USING is_row-last_req CHANGING lv_v.
  APPEND |<Cell ss:StyleID="{ lv_s }"><Data ss:Type="String">{ lv_v }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="{ lv_sn }"><Data ss:Type="Number">{ is_row-days_since }</Data></Cell>| TO lt_xml.
  APPEND |<Cell ss:StyleID="{ lv_sn }"><Data ss:Type="Number">{ is_row-last_price }</Data></Cell>| TO lt_xml.
  PERFORM xml_val USING is_row-currency CHANGING lv_v.
  APPEND |<Cell ss:StyleID="{ lv_s }"><Data ss:Type="String">{ lv_v }</Data></Cell>| TO lt_xml.
  APPEND '</Row>' TO lt_xml.
ENDFORM.

_xml '<Worksheet ss:Name="Repeated (Action)">'.
_xml '<Table ss:DefaultRowHeight="18">'.
_xml '<Column ss:Width="80"/>'.
_xml '<Column ss:Width="200"/>'.
_xml '<Column ss:Width="65"/>'.
_xml '<Column ss:Width="70"/>'.
_xml '<Column ss:Width="80"/>'.
_xml '<Column ss:Width="70"/>'.
_xml '<Column ss:Width="75"/>'.
_xml '<Column ss:Width="110"/>'.
_xml '<Column ss:Width="65"/>'.
_xml '<Column ss:Width="90"/>'.
_xml '<Column ss:Width="55"/>'.
_xml '<Row ss:Height="24">'.
_xml |<Cell ss:MergeAcross="10" ss:StyleID="title"><Data ss:Type="String">Auto PR Suggestion Report — Plant: { c_werks } | Location: { c_lgort } | Date: { sy-datum+6(2) }.{ sy-datum+4(2) }.{ sy-datum+0(4) }</Data></Cell>|.
_xml '</Row>'.
_xml '<Row ss:Height="8"><Cell/></Row>'.
_xml '<Row ss:Height="28">'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Material No.</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Material Name</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">PR Count</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Total Qty</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Last PR Date</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Last PR Qty</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Suggested Qty</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Last Requisitioner</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Days Since PR</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Last Price</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Currency</Data></Cell>'.
_xml '</Row>'.
lv_row = 0.
IF lt_rep IS INITIAL.
  _xml '<Row ss:Height="18"><Cell ss:StyleID="data"><Data ss:Type="String">(No repeated materials requiring action)</Data></Cell></Row>'.
ELSE.
  LOOP AT lt_rep INTO ls_row.
    lv_row += 1.
    PERFORM write_row1 USING ls_row lv_row.
  ENDLOOP.
ENDIF.
_xml '</Table></Worksheet>'.

_xml '<Worksheet ss:Name="One-Time (Action)">'.
_xml '<Table ss:DefaultRowHeight="18">'.
_xml '<Column ss:Width="130"/>'.
_xml '<Column ss:Width="80"/>'.
_xml '<Column ss:Width="200"/>'.
_xml '<Column ss:Width="65"/>'.
_xml '<Column ss:Width="70"/>'.
_xml '<Column ss:Width="80"/>'.
_xml '<Column ss:Width="70"/>'.
_xml '<Column ss:Width="75"/>'.
_xml '<Column ss:Width="110"/>'.
_xml '<Column ss:Width="65"/>'.
_xml '<Column ss:Width="90"/>'.
_xml '<Column ss:Width="55"/>'.
_xml '<Row ss:Height="24">'.
_xml |<Cell ss:MergeAcross="11" ss:StyleID="title"><Data ss:Type="String">Auto PR Suggestion Report — Plant: { c_werks } | Location: { c_lgort } | Date: { sy-datum+6(2) }.{ sy-datum+4(2) }.{ sy-datum+0(4) }</Data></Cell>|.
_xml '</Row>'.
_xml '<Row ss:Height="8"><Cell/></Row>'.
_xml '<Row ss:Height="28">'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Category</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Material No.</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Material Name</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">PR Count</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Total Qty</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Last PR Date</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Last PR Qty</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Suggested Qty</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Last Requisitioner</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Days Since PR</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Last Price</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Currency</Data></Cell>'.
_xml '</Row>'.
lv_row = 0.
IF lt_one IS INITIAL.
  _xml '<Row ss:Height="18"><Cell ss:StyleID="data"><Data ss:Type="String">(No one-time materials requiring action)</Data></Cell></Row>'.
ELSE.
  LOOP AT lt_one INTO ls_row.
    lv_row += 1.
    PERFORM write_row2 USING ls_row lv_row.
  ENDLOOP.
ENDIF.
_xml '</Table></Worksheet>'.

_xml '<Worksheet ss:Name="Suppressed (No Action)">'.
_xml '<Table ss:DefaultRowHeight="18">'.
_xml '<Column ss:Width="150"/>'.
_xml '<Column ss:Width="80"/>'.
_xml '<Column ss:Width="200"/>'.
_xml '<Column ss:Width="65"/>'.
_xml '<Column ss:Width="70"/>'.
_xml '<Column ss:Width="80"/>'.
_xml '<Column ss:Width="70"/>'.
_xml '<Column ss:Width="75"/>'.
_xml '<Column ss:Width="110"/>'.
_xml '<Column ss:Width="65"/>'.
_xml '<Column ss:Width="90"/>'.
_xml '<Column ss:Width="55"/>'.
_xml '<Row ss:Height="24">'.
_xml |<Cell ss:MergeAcross="11" ss:StyleID="title"><Data ss:Type="String">Auto PR Suggestion Report — Plant: { c_werks } | Location: { c_lgort } | Date: { sy-datum+6(2) }.{ sy-datum+4(2) }.{ sy-datum+0(4) }</Data></Cell>|.
_xml '</Row>'.
_xml '<Row ss:Height="8"><Cell/></Row>'.
_xml '<Row ss:Height="28">'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Category</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Material No.</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Material Name</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">PR Count</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Total Qty</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Last PR Date</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Last PR Qty</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Suggested Qty</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Last Requisitioner</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Days Since PR</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Last Price</Data></Cell>'.
_xml '<Cell ss:StyleID="header"><Data ss:Type="String">Currency</Data></Cell>'.
_xml '</Row>'.
lv_row = 0.
IF lt_blocked IS INITIAL.
  _xml '<Row ss:Height="18"><Cell ss:StyleID="data"><Data ss:Type="String">(No suppressed materials)</Data></Cell></Row>'.
ELSE.
  LOOP AT lt_blocked INTO ls_row.
    lv_row += 1.
    PERFORM write_row2 USING ls_row lv_row.
  ENDLOOP.
ENDIF.
_xml '</Table></Worksheet>'.

_xml '</Workbook>'.

DATA lv_xml_full TYPE string.
LOOP AT lt_xml INTO DATA(lv_xml_line).
  lv_xml_full = lv_xml_full && lv_xml_line && cl_abap_char_utilities=>newline.
ENDLOOP.

CALL FUNCTION 'SCMS_STRING_TO_XSTRING'
  EXPORTING text   = lv_xml_full
  IMPORTING buffer = lv_xstr.

CALL FUNCTION 'SCMS_XSTRING_TO_BINARY'
  EXPORTING buffer     = lv_xstr
  TABLES    binary_tab = lt_bin.

lv_size = xstrlen( lv_xstr ).

IF lt_rep IS INITIAL AND lt_one IS INITIAL.
  lv_subject = |Auto PR Suggest - NO ACTION ITEMS ({ sy-datum+6(2) }.{ sy-datum+4(2) }.{ sy-datum+0(4) })|.
  APPEND |No materials require ordering at this time.| TO lt_body.
ELSE.
  lv_subject = |Auto PR Suggest - Action Required ({ sy-datum+6(2) }.{ sy-datum+4(2) }.{ sy-datum+0(4) })|.
  APPEND |Please review the attached Excel file for PR suggestions.| TO lt_body.
ENDIF.
APPEND || TO lt_body.
APPEND |Summary:| TO lt_body.
APPEND |  Repeated (Action Required) : { lines( lt_rep ) }| TO lt_body.
APPEND |  One-Time (Action Required) : { lines( lt_one ) }| TO lt_body.
APPEND |  Suppressed (No Action)     : { lines( lt_blocked ) }| TO lt_body.
APPEND || TO lt_body.
APPEND |Filter : Plant={ c_werks }, Storage Location={ c_lgort }, All Purchasing Groups| TO lt_body.
APPEND |Period : { lv_from+6(2) }.{ lv_from+4(2) }.{ lv_from+0(4) } to { sy-datum+6(2) }.{ sy-datum+4(2) }.{ sy-datum+0(4) } (growing window - fixed start)| TO lt_body.
APPEND |Recent Threshold : { c_recent_days } days| TO lt_body.

DATA: lv_log_handle  TYPE balloghndl,
      lv_log_handle2 TYPE balloghndl,
      lv_log_handle3 TYPE balloghndl.

IF lt_recipients IS INITIAL.
  CALL FUNCTION 'BAL_LOG_CREATE'
    EXPORTING
      i_s_log = VALUE bal_s_log(
                  object    = 'ZMM_PR_SUGGEST'
                  subobject = 'NO_RECIP'
                  aluser    = sy-uname
                  alprog    = sy-repid )
    IMPORTING
      e_log_handle = lv_log_handle.
  CALL FUNCTION 'BAL_LOG_MSG_ADD_FREE_TEXT'
    EXPORTING
      i_log_handle = lv_log_handle
      i_msgty      = 'E'
      i_text       = |No recipients found - email not sent. Check ZMM_PR_SUGGEST_MAIL or hardcoded fallback.|.
  CALL FUNCTION 'BAL_DB_SAVE'
    EXPORTING
      i_log_handle = lv_log_handle.
  COMMIT WORK.
ELSE.

  TRY.
    DATA(lo_send) = cl_bcs=>create_persistent( ).
    DATA(lo_doc)  = cl_document_bcs=>create_document(
                      i_type    = 'RAW'
                      i_text    = lt_body
                      i_subject = lv_subject ).

    lo_doc->add_attachment(
      i_attachment_type    = 'XLS'
      i_attachment_subject = |Auto_PR_Suggest_{ sy-datum }.xls|
      i_attachment_size    = lv_size
      i_att_content_hex    = lt_bin ).

    lo_send->set_document( lo_doc ).

    LOOP AT lt_recipients INTO DATA(ls_recipient).
      lo_send->add_recipient(
        cl_cam_address_bcs=>create_internet_address( ls_recipient-email ) ).
    ENDLOOP.

    lo_send->set_send_immediately( abap_true ).
    lo_send->send( i_with_error_screen = abap_false ).
    COMMIT WORK.

  CATCH cx_send_req_bcs INTO DATA(lx_send).
    CALL FUNCTION 'BAL_LOG_CREATE'
      EXPORTING
        i_s_log = VALUE bal_s_log(
                    object    = 'ZMM_PR_SUGGEST'
                    subobject = 'SMTP_FAIL'
                    aluser    = sy-uname
                    alprog    = sy-repid )
      IMPORTING
        e_log_handle = lv_log_handle2.
    CALL FUNCTION 'BAL_LOG_MSG_ADD_FREE_TEXT'
      EXPORTING
        i_log_handle = lv_log_handle2
        i_msgty      = 'E'
        i_text       = |SMTP/BCS send failure - email was not delivered: { lx_send->get_text( ) }|.
    CALL FUNCTION 'BAL_DB_SAVE'
      EXPORTING
        i_log_handle = lv_log_handle2.
    COMMIT WORK.

  CATCH cx_root INTO DATA(lx_root).
    CALL FUNCTION 'BAL_LOG_CREATE'
      EXPORTING
        i_s_log = VALUE bal_s_log(
                    object    = 'ZMM_PR_SUGGEST'
                    subobject = 'DUMP'
                    aluser    = sy-uname
                    alprog    = sy-repid )
      IMPORTING
        e_log_handle = lv_log_handle3.
    CALL FUNCTION 'BAL_LOG_MSG_ADD_FREE_TEXT'
      EXPORTING
        i_log_handle = lv_log_handle3
        i_msgty      = 'A'
        i_text       = |Unexpected runtime error - possible dump: { lx_root->get_text( ) }|.
    CALL FUNCTION 'BAL_DB_SAVE'
      EXPORTING
        i_log_handle = lv_log_handle3.
    COMMIT WORK.

  ENDTRY.

ENDIF.
