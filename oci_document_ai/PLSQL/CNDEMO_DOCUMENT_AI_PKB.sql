CREATE OR REPLACE PACKAGE BODY CNDEMO_DOCUMENT_AI_PK AS
-------------------------------------------------------------------------------
-- NAME        : CNDEMO_DOCUMENT_AI_PK
-- FILE NAME   : CNDEMO_DOCUMENT_AI_PKB.sql
-- REVISION    : $2022.1.0$
-- PURPOSE     : Package containing code for the OCI Document AI Demo.
--
-- DELIVERED BY: $jdixon$
--               
-- Revision History:
-- VER        DATE         AUTHOR           DESCRIPTION
-- ========   ===========  ================ ===================================
-- 2022.1.0   25-JUL-2022  jdixon           Created.
-------------------------------------------------------------------------------

  GC_SCOPE_PREFIX  CONSTANT VARCHAR2(100) := 'demo.'||LOWER($$plsql_unit) || '.';

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
PROCEDURE put_file
 (p_mime_type         IN VARCHAR2,
  p_file_blob         IN BLOB,
  p_file_name         IN VARCHAR2,
  x_object_store_url OUT VARCHAR2) IS

  l_logger_scope        logger_logs.SCOPE%TYPE := GC_SCOPE_PREFIX || utl_call_stack.subprogram(1)(2);
  l_logger_params       logger.tab_param;
  l_response            CLOB;

BEGIN

  -- Build the full Object Storage URL.
  x_object_store_url := GC_OCI_OBJ_STORE_BASE_URL || p_file_name;

  logger.append_param(l_logger_params, 'object_store_url', x_object_store_url);
  logger.append_param(l_logger_params, 'file_name', p_file_name);

  -- Set Mime Type of the file in the Request Header.
  apex_web_service.g_request_headers.DELETE;
  apex_web_service.g_request_headers(1).name  := 'Content-Type';
  apex_web_service.g_request_headers(1).value := p_mime_type;

  -- Call Web Service to PUT file in OCI.
  l_response := apex_web_service.make_rest_request
   (p_url                  => UTL_URL.ESCAPE(x_object_store_url),
    p_http_method          => 'PUT',
    p_body_blob            => p_file_blob,
    p_credential_static_id => GC_WC_CREDENTIAL_ID);

  IF apex_web_service.g_status_code != 200 then
    logger.append_param(l_logger_params, 'status_code', apex_web_service.g_status_code);
    logger.append_param(l_logger_params, 'response', SUBSTR(l_response,1,255));
    logger.log_error('Error Adding File in OCI', l_logger_scope, NULL, l_logger_params);
    raise_application_error(-20111,'Unable to Upload File to OCI.');
  END IF;

  logger.log('Done', l_logger_scope, NULL, l_logger_params);

EXCEPTION WHEN OTHERS THEN
  logger.log_error('Error Uploading File ('||SQLERRM||')', l_logger_scope, NULL, l_logger_params);
  RAISE;
END put_file;

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
PROCEDURE upload_file
  (p_apex_file_name    IN VARCHAR2,
   x_file_name        OUT VARCHAR2,
   x_object_store_url OUT VARCHAR2,
   x_document_id      OUT cndemo_document_ai_docs.document_id%TYPE) IS

  CURSOR cr_file_info IS
    SELECT filename
    ,      blob_content
    ,      mime_type
    FROM   apex_application_temp_files
    WHERE  name = p_apex_file_name;

  l_logger_scope        logger_logs.SCOPE%TYPE := GC_SCOPE_PREFIX || utl_call_stack.subprogram(1)(2);
  l_logger_params       logger.tab_param;
  lr_file_info          cr_file_info%ROWTYPE;

BEGIN

  logger.log('Start', l_logger_scope, NULL, l_logger_params);

  -- Get the File BLOB Content and File Name uploaded from APEX.
  OPEN  cr_file_info;
  FETCH cr_file_info INTO lr_file_info;
  CLOSE cr_file_info;
  
  x_file_name := lr_file_info.filename;
  
  -- Post file to OCI Object Store.
  put_file
   (p_mime_type        => lr_file_info.mime_type,
    p_file_blob        => lr_file_info.blob_content,
    p_file_name        => lr_file_info.filename,
    x_object_store_url => x_object_store_url);

  -- Create Document Record
  INSERT INTO cndemo_document_ai_docs (file_name, mime_type, object_store_url)
  VALUES (lr_file_info.filename, lr_file_info.mime_type, x_object_store_url) 
  RETURNING document_id INTO x_document_id;

  logger.log('End', l_logger_scope, NULL, l_logger_params);

EXCEPTION WHEN OTHERS THEN
  logger.log_error('Unhandled Error[ '||SQLERRM||']', l_logger_scope, NULL, l_logger_params);
  RAISE;
END upload_file;

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
PROCEDURE document_ai
  (p_file_name   IN VARCHAR2,
   p_document_id IN cndemo_document_ai_docs.document_id%TYPE) IS

  CURSOR cr_document_data (cp_json IN CLOB) IS
    SELECT jt.*
    FROM   JSON_TABLE(cp_json, '$'
             COLUMNS (document_type_code      VARCHAR2(50)  PATH '$.detectedDocumentTypes[0].documentType',
                      document_type_score     NUMBER        PATH '$.detectedDocumentTypes[0].confidence',
                      language_code           VARCHAR2(50)  PATH '$.detectedLanguages[0].languageCode',
                      language_score          NUMBER        PATH '$.detectedLanguages[0].confidence',
                      page_count              NUMBER        PATH '$.documentMetadata.pageCount')) jt;

  CURSOR cr_document_fields (cp_json IN CLOB) IS
    SELECT jt.*
    FROM   JSON_TABLE(cp_json, '$.pages[*]'
             COLUMNS (page_number       NUMBER        PATH '$.pageNumber',
                      NESTED PATH '$.documentFields[*]' COLUMNS
                       (field_type_code VARCHAR2(50)   PATH '$.fieldType',
                        field_label     VARCHAR2(100)  PATH '$.fieldLabel.name',
                        label_score     NUMBER         PATH '$.fieldLabel.confidence',
                        field_value     VARCHAR2(1000) PATH '$.fieldValue.value'
                        ))) jt
    WHERE  jt.field_type_code = 'KEY_VALUE';

  l_logger_scope        logger_logs.SCOPE%TYPE := GC_SCOPE_PREFIX || utl_call_stack.subprogram(1)(2);
  l_logger_params       logger.tab_param;
  l_request_json        VARCHAR2(32000);
  l_response_json       CLOB;
  lr_document_data      cr_document_data%ROWTYPE;

BEGIN

  logger.append_param(l_logger_params, 'document_id', p_document_id);
  logger.log('Start', l_logger_scope, NULL, l_logger_params);

  -- Replace the uploaded filename in the JSON payload to be sent to Document AI.
  l_request_json := REPLACE(GC_OCY_DOC_AI_PAYLOAD, '#FILE_NAME#', p_file_name);

  -- Set Content-Type in the Request Header. This is required by the Document AI REST Service.
  apex_web_service.g_request_headers.DELETE;
  apex_web_service.g_request_headers(1).name  := 'Content-Type';
  apex_web_service.g_request_headers(1).value := 'application/json';

  -- Call the Document AI analyzeDocument REST Web Service.
  l_response_json := apex_web_service.make_rest_request
   (p_url                  => GC_OCI_DOC_AI_URL,
    p_http_method          => 'POST',
    p_body                 => l_request_json,
    p_credential_static_id => 'APEX_OCI_BLOG_CREDENTIAL');

  IF apex_web_service.g_status_code != 200 then
    logger.append_param(l_logger_params, 'status_code', apex_web_service.g_status_code);
    logger.append_param(l_logger_params, 'response', SUBSTR(l_response_json,1,255));
    logger.log_error('Error Calling OCI Document AI', l_logger_scope, NULL, l_logger_params);
    raise_application_error(-20112,'Unable to call OCI Document AI.');
  END IF;

  -- Get Document Level Data from the JSON response.
  OPEN  cr_document_data (cp_json => l_response_json);
  FETCH cr_document_data INTO lr_document_data;
  CLOSE cr_document_data;

  logger.append_param(l_logger_params, 'language_code', lr_document_data.language_code);
  logger.append_param(l_logger_params, 'document_type_code', lr_document_data.document_type_code);
  
  -- Get Key Value Fields from JSON and populate table.
  FOR r_field IN cr_document_fields (cp_json => l_response_json) LOOP
    INSERT INTO cndemo_document_ai_fields (document_id,field_type_code,field_label,label_score,field_value)
    VALUES (p_document_id,r_field.field_type_code,r_field.field_label,r_field.label_score,r_field.field_value);
  END LOOP;
  
  -- Update Document Table with Results.
  UPDATE cndemo_document_ai_docs
  SET    doc_ai_json         = l_response_json
  ,      language_code       = lr_document_data.language_code
  ,      language_score      = lr_document_data.language_score
  ,      document_type_code  = lr_document_data.document_type_code
  ,      document_type_score = lr_document_data.document_type_score
  ,      page_count          = lr_document_data.page_count
  WHERE  document_id         = p_document_id;

  logger.log('End', l_logger_scope, NULL, l_logger_params);

EXCEPTION WHEN OTHERS THEN
  logger.log_error('Unhandled Error[ '||SQLERRM||']', l_logger_scope, NULL, l_logger_params);
  RAISE;
END document_ai;

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
PROCEDURE process_file
  (p_apex_file_name  IN VARCHAR2,
   x_document_id    OUT cndemo_document_ai_docs.document_id%TYPE) IS

  l_logger_scope        logger_logs.SCOPE%TYPE := GC_SCOPE_PREFIX || utl_call_stack.subprogram(1)(2);
  l_logger_params       logger.tab_param;
  l_object_store_url    VARCHAR2(1000);
  l_file_name           VARCHAR2(100);

BEGIN

  logger.log('Start', l_logger_scope, NULL, l_logger_params);

  -- Get file and upload to OCI Object Storage.
  upload_file
   (p_apex_file_name   => p_apex_file_name, 
    x_file_name        => l_file_name,
    x_object_store_url => l_object_store_url,
    x_document_id      => x_document_id);

  logger.append_param(l_logger_params, 'document_id', x_document_id);
  
  -- Call OCI Document AI and parse the results.
  document_ai
    (p_file_name   => l_file_name,
     p_document_id => x_document_id);

  logger.log('End', l_logger_scope, NULL, l_logger_params);

EXCEPTION WHEN OTHERS THEN
  logger.log_error('Unhandled Error[ '||SQLERRM||']', l_logger_scope, NULL, l_logger_params);
  RAISE;
END process_file;

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
FUNCTION get_file (p_request_url IN VARCHAR2) RETURN BLOB IS

  l_logger_scope        logger_logs.SCOPE%TYPE := GC_SCOPE_PREFIX || utl_call_stack.subprogram(1)(2);
  l_logger_params       logger.tab_param;
  l_file_blob           BLOB;

BEGIN

  logger.append_param(l_logger_params, 'request_url', p_request_url);
  
  -- Call OCI Web Service to get the requested file.
  l_file_blob := apex_web_service.make_rest_request_b
   (p_url                  => UTL_URL.ESCAPE(p_request_url),
    p_http_method          => 'GET',
    p_credential_static_id => GC_WC_CREDENTIAL_ID);

  IF apex_web_service.g_status_code != 200 then
    logger.append_param(l_logger_params, 'status_code', apex_web_service.g_status_code);
    logger.log_error('Error Getting File in OCI', l_logger_scope, NULL, l_logger_params);
    raise_application_error(-20112,'Unable to Get File.');
  END IF;
  
  RETURN l_file_blob;
  
EXCEPTION WHEN OTHERS THEN
  logger.log_error('Error Getting File ('||SQLERRM||')', l_logger_scope, NULL, l_logger_params);
  RAISE;
END get_file;

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
PROCEDURE render_document
  (x_document_id  IN cndemo_document_ai_docs.document_id%TYPE) IS

  CURSOR cr_document IS
    SELECT mime_type
    ,      object_store_url
    FROM   cndemo_document_ai_docs
    WHERE  document_id = x_document_id;

  l_logger_scope        logger_logs.SCOPE%TYPE := GC_SCOPE_PREFIX || utl_call_stack.subprogram(1)(2);
  l_logger_params       logger.tab_param;
  lr_document           cr_document%ROWTYPE;
  l_file_blob           BLOB;

BEGIN

  -- Get the OCI URL and Mimetytpe of the receipt file.
  OPEN  cr_document;
  FETCH cr_document INTO lr_document;
  CLOSE cr_document;

  -- Get the file BLOB from OCI Object Storage.
  l_file_blob := get_file (p_request_url => lr_document.object_store_url);

  -- Output the file so it shows in APEX.
  owa_util.mime_header(lr_document.mime_type,false);
  htp.p('Content-Length: ' || dbms_lob.getlength(l_file_blob)); 
  owa_util.http_header_close;  
  wpg_docload.download_file(l_file_blob);

  logger.log('End', l_logger_scope, NULL, l_logger_params);

EXCEPTION WHEN OTHERS THEN
  logger.log_error('Unhandled Error[ '||SQLERRM||']', l_logger_scope, NULL, l_logger_params);
  RAISE;
END render_document;

END CNDEMO_DOCUMENT_AI_PK;
/