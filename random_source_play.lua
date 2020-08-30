local obs = obslua

-- Global variables
local sampler = {}
local source_names = {}
local hk = {}
local hotkeys = {
    RANDOM_PLAY = "ソースのランダム再生",
}
----------------------------------------------------------
-- PartitionTree
PartitionTree = {}
PartitionTree.__index = PartitionTree
function PartitionTree:new(intervals, labels)
    local function add_interval(interval, node)
        if node.interval == nil then
            node.interval = interval
            node.left = {}
            node.right = {}
        elseif interval[2] <= node.interval[1] then
            add_interval(interval, node.left)
        elseif interval[1] >= node.interval[2] then
            add_interval(interval, node.right)
        else
            obs.script_log(obs.OBS_WARNING, "Error in add_interval()")
        end
    end
    local o = {}
    setmetatable(o, PartitionTree)

    o.root = {}
    o.mapping = {}
    for i = 1, #intervals do
        local interval = intervals[i]
        local label = labels[i]
        add_interval(interval, o.root)
        local key = string.format("%f-%f", interval[1], interval[2])
        o.mapping[key] = label
    end
    return o
end

function PartitionTree:get_label(value)
    local function get_interval(value, node)
        local left_bound = node.interval[1]
        local right_bound = node.interval[2]
        if value < left_bound then
            return get_interval(value, node.left)
        elseif value > right_bound then
            return get_interval(value, node.right)
        else
            return node.interval
        end
    end
    local interval = get_interval(value, self.root)
    local key = string.format("%f-%f", interval[1], interval[2])
    return self.mapping[key]
end

-- Multinomial Sampler
MultinomialSampler = {}
MultinomialSampler.__index = MultinomialSampler
function MultinomialSampler:new(probs, labels)
    local function build_intervals_from_probs(ps)
        -- Check if probs add up to 1.0
        local acc = 0
        for _, v in ipairs(ps) do
            acc = acc + v
        end
        -- Comparing in string form to avoid float point error
        if tostring(acc) ~= tostring(1.0) then
            warn(string.format("Sum of probabilities: %f != 1.0", acc))
        end
        -- Generate intervals
        local intervals = {}
        local left_side = 0.0
        for i, p in ipairs(ps) do
            intervals[i] = {left_side, left_side + p}
            left_side = left_side + p
        end
        return intervals
    end
    local o = {}
    setmetatable(o, MultinomialSampler)
    local intervals = build_intervals_from_probs(probs)
    o.tree = PartitionTree:new(intervals, labels)
    return o
end

function MultinomialSampler:sample()
    local val = math.random()
    return self.tree:get_label(val)
end

----------------------------------------------------------
local function warn(message)
    obs.script_log(obs.OBS_WARNING, message)
end

local function info(message)
    obs.script_log(obs.OBS_INFO, message)
end

local function set_status(settings, status_text)
    info("settings status text")
    obs.obs_data_set_default_string(settings, "status", status_text)
end

local function parse_probs(probs_text)
    local probs = {}
    local i = 1
    for prob in string.gmatch(probs_text, "([^:]+)") do
        local num = tonumber(prob)
        if num ~= nil then
            probs[i] = num
            i = i + 1
        end
    end
    return probs
end

local function init_sampler(probs)
    local labels = {}
    for i = 1, #probs do
        labels[i] = i
    end
    sampler = MultinomialSampler:new(probs, labels)
end

local function get_current_scene_name()
    local scene_source = obs.obs_frontend_get_current_scene()
    local name = obs.obs_source_get_name(scene_source)
    obs.obs_source_release(scene_source)
    return name
end

local function play_random_source(pressed)
    if not pressed then return end
    -- Check everything before playing source
    if #source_names == 0 then
        info("Error: ソースが一つも選択されていません")
        return
    end
    local n_source = 0
    for _, name in ipairs(source_names) do
        -- Check if source with this name exists
        local source = obs.obs_get_source_by_name(name)
        if source == nil then
            warn(string.format("Error: ソース「%s」が存在しません", name))
        else
            info(string.format("Ok: ソース「%s」の存在を確認しました", name))
            n_source = n_source + 1
        end
        obs.obs_source_release(source)
    end
    if #source_names ~= n_source then
        warn(string.format("Error: 選択したソース名の数 %d != 確認できたソースの数 %d", #source_names, n_source))
        return
    end
    local idx = sampler:sample()
    info(string.format("Ok: ソース「%s」を選択", source_names[idx]))
    local scene_source = obs.obs_get_source_by_name(get_current_scene_name())
    local scene = obs.obs_scene_from_source(scene_source)
    local sceneitem = obs.obs_scene_find_source(scene, source_names[idx])
    if not sceneitem then
        warn(string.format("Error: 現在のシーンにソース「%s」が存在しません", source_names[idx]))
    else
        obs.obs_sceneitem_set_visible(sceneitem, true)
        local source = obs.obs_sceneitem_get_source(sceneitem)
        local source_data = obs.obs_save_source(source)
        obs.obs_source_update(source, source_data)
        obs.obs_data_release(source_data)
    end
    obs.obs_source_release(scene_source)
end

-- Override functions
-- Descriptions
function script_description()
    -- return "Randomly choose a single source from selected sources"
    return "選択されたソース一覧からランダムにひとつ選んで再生するスクリプト"
end

-- A function called when settings are changed
function script_update(settings)
    info("--- Script updated ---")

    local selected_sources = obs.obs_data_get_array(settings, "media_sources")
    local n_source_names = obs.obs_data_array_count(selected_sources)
    local status = ""
    source_names = {}
    for i = 1, n_source_names do
        local source_obj = obs.obs_data_array_item(selected_sources, i - 1)
        local source_name = obs.obs_data_get_string(source_obj, "value")
        source_names[i] = source_name
    end
    obs.obs_data_array_release(selected_sources)
    if #source_names == 0 then return end
    -- Initalize play probabilities
    local prob_str = obs.obs_data_get_string(settings, "probs")
    local probs = parse_probs(prob_str)
    local normalized_probs = {}
    if (#probs == #source_names) then
        -- Normalize probability ratio
        local acc = 0.0
        for _, p in ipairs(probs) do
            acc = acc + p
        end
        for i, p in ipairs(probs) do
            normalized_probs[i] = p / acc
        end
    else
        -- Equal proabilities if probs cannot be parsed properly
        local prob = 1.0 / n_source_names
        for i, _ in ipairs(source_names) do
            normalized_probs[i] = prob
        end
    end

    for i, _ in ipairs(source_names) do
        status = status .. string.format("%s: %f\n", source_names[i], normalized_probs[i])
    end
    info(status)

    -- Initialize multinomial sampler
    init_sampler(normalized_probs)
end

-- Set user-configurable properties
function script_properties()
    info("--- Script properties configured ---")
    local props = obs.obs_properties_create()
    local p_sources = obs.obs_properties_add_editable_list(props, "media_sources", "選択ソース一覧", obs.OBS_EDITABLE_LIST_TYPE_STRINGS, nil, nil)
    local p_probs = obs.obs_properties_add_text(props, "probs", "確率比", obs.OBS_TEXT_DEFAULT)
    return props
end

-- A fuction called on startup
function script_load(settings)
    info("--- Script loaded ---")
    math.randomseed(os.clock()*100000000000)
    for k, v in pairs(hotkeys) do
        hk[k] = obs.obs_hotkey_register_frontend(k, v, play_random_source)
        local hotkey_save_array = obs.obs_data_get_array(settings, k)
        obs.obs_hotkey_load(hk[k], hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end
end

-- A fuction called on save
function script_save(settings)
    for k, v in pairs(hotkeys) do
        local hotkey_save_array = obs.obs_hotkey_save(hk[k])
        obs.obs_data_set_array(settings, k, hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end
end
