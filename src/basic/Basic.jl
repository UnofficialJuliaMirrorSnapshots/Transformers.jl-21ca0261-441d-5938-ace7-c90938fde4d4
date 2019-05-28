module Basic

using Flux
using Requires
using Requires: @init

using ..Transformers: Abstract3DTensor, Container, batchedmul

export CompositeEmbeddings
export PositionEmbedding, Embed, getmask,
    Vocabulary, gather, encode, decode
export OneHotArray, indices2onehot, onehot2indices,
    onehotarray, onehot, tofloat
export Transformer, TransformerDecoder

export @toNd, Positionwise

export logkldivergence, logcrossentropy

include("./extend3d.jl")
include("./embeds/Embeds.jl")
include("./mh_atten.jl")
include("./transformer.jl")
include("./loss.jl")

end
