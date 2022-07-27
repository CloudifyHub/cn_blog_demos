-- Generated by ORDS REST Data Services 22.2.0.r1681700
-- 14-JUL-2022 Initial version.

BEGIN
  ORDS.DEFINE_MODULE(
      p_module_name    => 'teams',
      p_base_path      => '/teams/',
      p_items_per_page => 25,
      p_status         => 'PUBLISHED',
      p_comments       => 'Module used to host REST Services for Teams Integrations.');

  ORDS.DEFINE_TEMPLATE(
      p_module_name    => 'teams',
      p_pattern        => 'incoming_webhook_response',
      p_priority       => 0,
      p_etag_type      => 'HASH',
      p_etag_query     => NULL,
      p_comments       => 'Demo response from an Incoming Webhook Action Card');

  ORDS.DEFINE_HANDLER(
      p_module_name    => 'teams',
      p_pattern        => 'incoming_webhook_response',
      p_method         => 'POST',
      p_source_type    => 'plsql/block',
      p_mimes_allowed  => 'application/json',
      p_comments       => NULL,
      p_source         => 
'DECLARE
  l_payload_clob   CLOB;
BEGIN
  l_payload_clob := :BODY_TEXT;
  cndemo_teams_ib_webhook_pk.capture_card_response
   (p_request       => l_payload_clob,
    p_respone_token => :response_token,
    x_status        => :status);
END;');

  ORDS.DEFINE_PARAMETER(
      p_module_name        => 'teams',
      p_pattern            => 'incoming_webhook_response',
      p_method             => 'POST',
      p_name               => 'X-ORDS-STATUS-CODE',
      p_bind_variable_name => 'status',
      p_source_type        => 'HEADER',
      p_param_type         => 'INT',
      p_access_method      => 'OUT',
      p_comments           => NULL);

  ORDS.DEFINE_PARAMETER(
      p_module_name        => 'teams',
      p_pattern            => 'incoming_webhook_response',
      p_method             => 'POST',
      p_name               => 'Authorization',
      p_bind_variable_name => 'authorization',
      p_source_type        => 'HEADER',
      p_param_type         => 'STRING',
      p_access_method      => 'IN',
      p_comments           => NULL);
    
COMMIT;
END;
/