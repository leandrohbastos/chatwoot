# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

class ChamadosController < ActionController::Base
  protect_from_forgery with: :null_session

  QUERY_URL = 'http://75.119.148.104:3055/query'
  SQL_QUERY = <<~SQL.squish
    SELECT CASE WHEN UPPER(i.nome_fantasia) LIKE '%ARARI%' THEN 'MA' WHEN UPPER(i.nome_fantasia) LIKE '%ARCHER%' THEN 'MA' WHEN UPPER(i.nome_fantasia) LIKE '%CAXIAS%' THEN 'MA' WHEN UPPER(i.nome_fantasia) LIKE '%TIMON%' THEN 'MA' WHEN UPPER(i.nome_fantasia) LIKE '%INFORGENESES%' THEN 'MA' ELSE COALESCE(u.uf, cid.uf, 'MA') END AS UF, CASE WHEN UPPER(i.nome_fantasia) LIKE '%ARARI%' THEN 'Arari' ELSE COALESCE(cid.nome, 'Não informada') END AS Cidade, CONCAT(c.num_chamado, ' ', DATE_FORMAT(c.data_abertura, '%d/%m/%Y')) AS Protocolo_Data, DATEDIFF(NOW(), c.data_abertura) AS Dias_Atraso, c.assunto AS Assunto, COALESCE(m.descricao, 'Sem Módulo/Projeto') AS Finalidade_Modulo, i.nome_fantasia AS Instituicao, COALESCE(u_criador.nome, 'Não informado') AS Criador, COALESCE(u_resp.nome, u_criador.nome, 'Sem Responsável') AS Responsavel, COALESCE(u_resp_atual.nome, 'Sem Resp. Interno') AS Resp_interno, COALESCE(p.descricao, 'Normal') AS Prioridade, s.descricao AS Status_Atual FROM chamado c LEFT JOIN modulo m ON c.modulo_id = m.id LEFT JOIN instituicao i ON c.instituicao_id = i.id LEFT JOIN cidade cid ON i.cidade_id = cid.id LEFT JOIN uf u ON i.uf_id = u.id LEFT JOIN usuario u_criador ON c.usuario_id = u_criador.id LEFT JOIN usuario u_resp ON c.responsavel_id = u_resp.id LEFT JOIN usuario u_resp_atual ON c.responsavel_atual_id = u_resp_atual.id LEFT JOIN prioridade p ON c.prioridade_id = p.id LEFT JOIN situacao s ON c.situacao_atual = s.id WHERE (c.num_chamado LIKE '%.2026%' OR YEAR(c.data_abertura) = 2026) AND c.situacao_atual NOT IN ('2', '3', '5', '6', '9', '20', '35', '39', '41', '47') AND c.situacao_atual NOT IN ('15', '21', '22', '23', '24', '25', '26', '27', '28', '29', '36', '37', '38', '40', '42', '44', '48', '52') ORDER BY c.data_abertura DESC, i.nome_fantasia ASC;
  SQL

  def index
    allow_iframe_embedding
    render template: 'chamados/index', layout: false
  end

  def widget
    allow_iframe_embedding
    render template: 'chamados/widget', layout: false
  end

  def data
    chamados = fetch_chamados(force: params[:refresh].present?)

    if params[:instituicao].present?
      inst = params[:instituicao].to_s.upcase.strip
      chamados = chamados.select do |c|
        c['Instituicao'].to_s.upcase.include?(inst)
      end
    end

    if params[:busca].present?
      term = params[:busca].to_s.upcase.strip
      chamados = chamados.select do |c|
        c['Assunto'].to_s.upcase.include?(term) ||
          c['Protocolo_Data'].to_s.upcase.include?(term) ||
          c['Instituicao'].to_s.upcase.include?(term)
      end
    end

    render json: {
      lista_chamados: chamados,
      total: chamados.size,
      timestamp: Time.current.to_i * 1000
    }
  rescue StandardError => e
    Rails.logger.error "[ChamadosController] Falha ao consultar API: #{e.message}"
    render json: { error: e.message, lista_chamados: [], total: 0 }, status: :ok
  end

  private

  def allow_iframe_embedding
    response.headers.delete('X-Frame-Options')
    response.headers['Content-Security-Policy'] = "frame-ancestors 'self' *"
  end

  def fetch_chamados(force: false)
    cache_key = 'inforgeneses_chamados_cache_v1'
    Rails.cache.delete(cache_key) if force

    Rails.cache.fetch(cache_key, expires_in: 45.seconds) do
      uri = URI.parse(QUERY_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 8
      http.read_timeout = 15

      req = Net::HTTP::Post.new(uri.request_uri, { 'Content-Type' => 'application/json' })
      req.body = { query: SQL_QUERY }.to_json

      res = http.request(req)
      if res.is_a?(Net::HTTPSuccess)
        parsed = JSON.parse(res.body)
        parsed.is_a?(Array) ? parsed : (parsed['data'] || [])
      else
        raise "API retornou código #{res.code}: #{res.body}"
      end
    end
  end
end
