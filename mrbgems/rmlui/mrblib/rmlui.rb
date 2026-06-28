# Friendly Ruby surface for RmlUi, built on the low-level Rml._* primitives.
# Implements the subset of docs/API_SPEC_RMLUI.md needed for the first milestone:
# init, fonts, a Context, loading + showing a static document, and the per-frame
# update/render/input cycle.

module Rml
  class << self
    # Must be called AFTER Rl.init_window (needs the GL context).
    def init
      _init
    end

    def shutdown
      _shutdown
    end

    def load_font(path, fallback: false)
      _load_font(path.to_s, fallback)
    end
  end

  # A node in the RML document tree. Wraps a native Element* (non-owning).
  # (API_SPEC_RMLUI 6)
  class Element
    attr_reader :ptr
    def initialize(ptr); @ptr = ptr; end

    # attributes
    def [](name)        = Rml._el_get_attribute(@ptr, name.to_s)
    def []=(name, v); Rml._el_set_attribute(@ptr, name.to_s, v.to_s); end
    def attribute(name) = Rml._el_get_attribute(@ptr, name.to_s)
    def set_attribute(name, v); Rml._el_set_attribute(@ptr, name.to_s, v.to_s); self; end
    def has_attribute?(name) = Rml._el_has_attribute(@ptr, name.to_s)
    def remove_attribute(name); Rml._el_remove_attribute(@ptr, name.to_s); self; end

    # identity / content
    def id          = Rml._el_get_id(@ptr)
    def id=(v); Rml._el_set_id(@ptr, v.to_s); end
    def tag_name    = Rml._el_tag(@ptr)
    def inner_rml   = Rml._el_get_inner_rml(@ptr)
    def inner_rml=(v); Rml._el_set_inner_rml(@ptr, v.to_s); end
    alias_method :text, :inner_rml
    def text=(v); Rml._el_set_inner_rml(@ptr, v.to_s); end

    # classes / style properties
    def set_class(name, on); Rml._el_set_class(@ptr, name.to_s, on); self; end
    def add_class(name);    set_class(name, true); end
    def remove_class(name); set_class(name, false); end
    def class_set?(name) = Rml._el_is_class_set(@ptr, name.to_s)
    def set_property(name, val); Rml._el_set_property(@ptr, name.to_s, val.to_s); self; end
    def property(name)  = Rml._el_get_property(@ptr, name.to_s)
    def remove_property(name); Rml._el_remove_property(@ptr, name.to_s); self; end

    # actions
    def focus; Rml._el_focus(@ptr); self; end
    def blur;  Rml._el_blur(@ptr);  self; end
    def click; Rml._el_click(@ptr); self; end
    def scroll_into_view(align_top = true); Rml._el_scroll_into_view(@ptr, align_top); self; end
    def visible? = Rml._el_is_visible(@ptr)
    def select_all; Rml._el_select(@ptr); self; end
    def set_selection_range(start, finish); Rml._el_set_selection_range(@ptr, start, finish); self; end
    def caret_end; v = self["value"].to_s; set_selection_range(v.length, v.length); self; end

    # traversal / queries (return Element / Array<Element> / nil)
    def element(id)            = Rml._el_get_element_by_id(@ptr, id.to_s)
    alias_method :get_element_by_id, :element
    def query_selector(sel)    = Rml._el_query_selector(@ptr, sel.to_s)
    def query_selector_all(sel) = Rml._el_query_selector_all(@ptr, sel.to_s)
    def elements_by_tag(tag)   = Rml._el_get_elements_by_tag(@ptr, tag.to_s)
    def parent          = Rml._el_parent(@ptr)
    def child_count     = Rml._el_num_children(@ptr)
    def child(i)        = Rml._el_child(@ptr, i)
    def children        = (0...child_count).map { |i| child(i) }
    def owner_document  = Rml._el_owner_document(@ptr)

    # geometry
    def client_width  = Rml._el_client_width(@ptr)
    def client_height = Rml._el_client_height(@ptr)
    def offset_left   = Rml._el_offset_left(@ptr)
    def offset_top    = Rml._el_offset_top(@ptr)
    def absolute_left = Rml._el_absolute_left(@ptr)
    def absolute_top  = Rml._el_absolute_top(@ptr)

    # events: el.on(:click) { |event| ... }
    def on(type, &block); Rml._el_add_event_listener(@ptr, type.to_s, &block); self; end
  end

  # An event delivered to an Element#on listener. (API_SPEC_RMLUI 5)
  class Event
    def initialize(ptr); @ptr = ptr; end
    def type    = Rml._ev_type(@ptr)
    def target  = Rml._ev_target(@ptr)
    def current = Rml._ev_current(@ptr)
    def stop_propagation;           Rml._ev_stop_propagation(@ptr); end
    def stop_immediate_propagation; Rml._ev_stop_immediate(@ptr); end
    def [](key)        = Rml._ev_param_float(@ptr, key.to_s)
    def param(key)     = Rml._ev_param_float(@ptr, key.to_s)
    def param_str(key) = Rml._ev_param_str(@ptr, key.to_s)
    def mouse_x = param("mouse_x")
    def mouse_y = param("mouse_y")
  end

  # An ElementDocument: an Element with show/hide/title/etc.
  class Document < Element
    def show; Rml._document_show(@ptr); self; end
    def hide; Rml._document_hide(@ptr); self; end
    def close; Rml._doc_close(@ptr); self; end
    def title      = Rml._doc_title(@ptr)
    def title=(t); Rml._doc_set_title(@ptr, t.to_s); end
    def pull_to_front; Rml._doc_pull_to_front(@ptr); self; end
    def push_to_back;  Rml._doc_push_to_back(@ptr);  self; end
  end

  # MVC data model: binds Ruby state to {{vars}} / data-* attributes in RML.
  # (API_SPEC_RMLUI 4)
  class DataModel
    def initialize(ctx_ptr, name)
      @getters = {}
      @values  = {}
      @events  = {}
      @ptr = Rml._data_model_create(ctx_ptr, name.to_s, self)
    end

    # one-way computed view: m.bind(:hp) { player.hp }
    def bind(name, &getter)
      @getters[name.to_s] = getter
      Rml._data_model_bind_get(@ptr, name.to_s)
      self
    end

    # two-way scalar: m.value(:volume, 0.5)
    def value(name, initial)
      @values[name.to_s] = initial
      Rml._data_model_bind_scalar(@ptr, name.to_s)
      self
    end

    # controller callback: m.event(:reset) { ... }  (rml: data-event-click="reset()")
    def event(name, &blk)
      @events[name.to_s] = blk
      Rml._data_model_bind_event(@ptr, name.to_s)
      self
    end

    def finish
      Rml._data_model_finish(@ptr)
      self
    end

    # notify the view that bound variables changed (DataModelHandle::DirtyVariable)
    def dirty(*names)
      names.each { |n| Rml._data_model_dirty(@ptr, n.to_s) }
      self
    end

    def dirty_all
      Rml._data_model_dirty_all(@ptr)
      self
    end

    def [](name)
      @values[name.to_s]
    end

    def []=(name, v)
      @values[name.to_s] = v
      Rml._data_model_dirty(@ptr, name.to_s)
    end

    # --- called from the C++ bridge ---
    def __get(name)
      @getters.key?(name) ? @getters[name].call : @values[name]
    end

    def __set(name, v)
      @values[name] = v
    end

    def __event(name)
      blk = @events[name]
      blk.call if blk
    end
  end

  class Context
    def initialize(name, width: nil, height: nil)
      width  ||= Rl.screen_width
      height ||= Rl.screen_height
      @ptr = Rml._create_context(name.to_s, width, height)
      raise "failed to create RmlUi context #{name.inspect}" if @ptr.nil?
    end

    def dimensions=(vec2)
      Rml._context_set_dimensions(@ptr, vec2.x, vec2.y)
    end

    def resize(width, height)
      Rml._context_set_dimensions(@ptr, width, height)
    end

    # Create + configure a data model. Must be called BEFORE load_document so the
    # document can bind to it by name. (API_SPEC_RMLUI 4.1)
    def data_model(name)
      m = DataModel.new(@ptr, name)
      yield m if block_given?
      m.finish
      m
    end

    def load_document(path)
      ptr = Rml._context_load_document(@ptr, path.to_s)
      raise "failed to load document #{path}" if ptr.nil?
      doc = Document.new(ptr)
      yield doc if block_given?
      doc
    end

    # Look up an already-loaded document by its id/source. Returns a bare
    # Element wrapper (use load_document's return value for Document methods).
    def document(id)   = Rml._context_get_document(@ptr, id.to_s)
    def num_documents  = Rml._context_num_documents(@ptr)

    def process_input
      Rml._context_process_input(@ptr)
    end

    def update
      Rml._context_update(@ptr)
    end

    def render
      Rml._context_render(@ptr)
    end

    # Block helper: process_input before, update+render after (API_SPEC_RMLUI 2).
    def frame
      process_input
      yield
    ensure
      update
      render
    end
  end
end
