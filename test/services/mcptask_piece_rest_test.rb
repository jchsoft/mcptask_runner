# frozen_string_literal: true

require 'test_helper'
require 'socket'
require 'mcptask_runner/services/concerns/mcptask_piece_rest'

# Wire-format contract with mcptask.online's REST API, asserted against a real loopback socket
# rather than a stubbed Net::HTTP.
#
# Both reporters shipped broken because their unit tests mocked the shape the client SENT instead of
# the shape the server ACCEPTS: post_piece wrapped its attributes in {piece: …} and parsed
# {"piece":{"relative_id":…}} back, while Api::PiecesController#create permits attributes at the top
# level and renders them flat — every permitted key came through nil and find_by!(relative_id: nil)
# answered "HTTP 404 creating piece" in production, with green tests. Asserting real bytes is the
# only version of this test that can catch that class of mismatch, so the expectations below mirror
# projectoid_ii exactly:
#
#   PiecesController#create      params.permit(:piece_type, :name, :project_id, :parent_id, …)
#                                → flat JSON, project_id/parent_id are account-scoped relative_ids
#                                create.json.jbuilder renders json.extract! @piece, :id, :relative_id, …
#   AttachmentsController#create params[:file].tempfile / .original_filename / .content_type
#                                → multipart/form-data under field name "file"
class McptaskPieceRestTest < Minitest::Test
  # Minimal includer: the concern only needs a destination and credentials from its host class.
  class Client
    include McptaskRunner::Concerns::McptaskPieceRest

    def initialize(port)
      @port = port
    end

    # post_piece / attach_content are private in the concern; tests drive them through these.
    def create(attrs) = post_piece(attrs)
    def attach(piece_id, name, content) = attach_content(piece_id, name, content)

    private

    def account_code = 'jchsoft'
    def base_url = "http://127.0.0.1:#{@port}"
    def token = 'test-token'
  end

  def setup
    @server = TCPServer.new('127.0.0.1', 0)
    @requests = []
  end

  def teardown
    @thread&.join(2)
    @server.close unless @server.closed?
  end

  def test_post_piece_sends_flat_json_and_reads_flat_relative_id
    serve(1, body: { 'id' => 9876, 'relative_id' => 321, 'name' => 'Runner error' })

    piece_id = client.create(name: 'Runner error', project_id: 69, parent_id: 10_445, task_type_code: 'bug')

    assert_equal 321, piece_id, 'relative_id must be read from the flat create response'

    request = recorded_request
    assert_equal '/api/jchsoft/pieces', request[:path]
    assert_equal 'application/json', request[:headers]['content-type']
    assert_equal 'Bearer test-token', request[:headers]['authorization']

    body = JSON.parse(request[:body])
    refute body.key?('piece'), 'attributes must NOT be wrapped in a "piece" root — the API permits them top-level'
    assert_equal 69, body['project_id']
    assert_equal 10_445, body['parent_id']
    assert_equal 'bug', body['task_type_code']
  end

  def test_post_piece_raises_on_non_success
    serve(1, code: 404, reason: 'Not Found', body: { 'status' => 404, 'error' => 'Not Found' })

    error = assert_raises(McptaskRunner::Concerns::McptaskPieceRest::Error) { client.create(name: 'x', project_id: 69) }
    assert_equal 'HTTP 404 creating piece', error.message
  end

  def test_post_piece_raises_when_relative_id_absent
    serve(1, body: { 'id' => 9876, 'name' => 'no relative_id here' })

    error = assert_raises(McptaskRunner::Concerns::McptaskPieceRest::Error) { client.create(name: 'x', project_id: 69) }
    assert_equal "no 'relative_id' in create response", error.message
  end

  def test_attach_content_sends_multipart_file_upload
    serve(1, body: { 'id' => 1, 'filename' => 'run_42.json' })

    client.attach(321, 'run_42.json', '{"status":"error"}')

    request = recorded_request
    assert_equal '/api/jchsoft/pieces/321/attachments', request[:path], 'piece_id in the path is the relative_id create returned'
    assert_match %r{\Amultipart/form-data; boundary=}, request[:headers]['content-type']
    assert_match(/name="file"; filename="run_42\.json"/, request[:body], 'API reads params[:file].original_filename')
    assert_includes request[:body], '{"status":"error"}'
    refute_includes request[:body], 'file_content', 'must not fall back to the JSON+base64 shape'
  end

  def test_attach_content_raises_on_non_success
    serve(1, code: 400, reason: 'Bad Request', body: { 'status' => 400, 'error' => 'param is missing: file' })

    error = assert_raises(McptaskRunner::Concerns::McptaskPieceRest::Error) { client.attach(321, 'run_42.json', 'x') }
    assert_equal 'HTTP 400 attaching run_42.json', error.message
  end

  private

  def client
    Client.new(@server.addr[1])
  end

  # The server thread appends to @requests only after it has answered, which can trail the client's
  # return — join before asserting on what was received.
  def recorded_request
    @thread.join(2)
    @requests.first
  end

  # Accept `count` requests on the loopback server, record each one, and answer with the canned
  # response. Runs on its own thread so the client's blocking call can complete.
  def serve(count, code: 201, reason: 'Created', body: {})
    payload = JSON.generate(body)
    @thread = Thread.new do
      count.times { @requests << read_request(@server.accept, payload, code, reason) }
    end
  end

  def read_request(socket, payload, code, reason)
    head = +''
    head << socket.readpartial(4096) until head.include?("\r\n\r\n")
    head, _, rest = head.partition("\r\n\r\n")
    request_line, *header_lines = head.lines.map(&:chomp)
    headers = header_lines.to_h { |line| line.split(': ', 2) }.transform_keys(&:downcase)
    body = read_body(socket, rest, headers['content-length'].to_i)
    socket.print("HTTP/1.1 #{code} #{reason}\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\n\r\n#{payload}")
    socket.close
    { path: request_line.split[1], headers: headers, body: body }
  end

  def read_body(socket, partial, length)
    body = +partial
    body << socket.readpartial(4096) while body.bytesize < length
    body
  end
end
