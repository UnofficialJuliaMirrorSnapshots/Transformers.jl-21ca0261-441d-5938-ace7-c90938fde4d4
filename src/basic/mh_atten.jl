using Flux
using Flux: @treelike
using Flux.Tracker: data
using LinearAlgebra: tril!

struct MultiheadAttention
    head::Int
    future::Bool
    iqproj::Dense
    ikproj::Dense
    ivproj::Dense
    oproj::Dense
    drop::Dropout
end

@treelike MultiheadAttention

"""
    MultiheadAttention(head::Int, is::Int, hs::Int, os::Int; future::Bool=true, pdrop = 0.1)

Multihead dot product Attention Layer, `head` is the number of head, `is` is the input size, `hs` is the hidden size of input projection layer of each head,
`os` is the output size. When `future` is `false`, the k-th token can't see tokens at > k. `pdrop` is the dropout rate.
"""
MultiheadAttention(head::Int,
                   is::Int,
                   hs::Int,
                   os::Int;
                   future::Bool=true, pdrop = 0.1) = MultiheadAttention(head,
                                                                        future,
                                                                        Dense(is, hs*head),
                                                                        Dense(is, hs*head),
                                                                        Dense(is, hs*head),
                                                                        Dense(hs*head, os),
                                                                        Dropout(pdrop),
                                                                        )


function Base.show(io::IO, mh::MultiheadAttention)
    hs = div(size(mh.iqproj.W)[1], mh.head)
    is = size(mh.iqproj.W)[end]
    os = size(mh.oproj.W)[1]

    print(io, "MultiheadAttention(")
    print(io, "head=$(mh.head), ")
    print(io, "head_size=$(hs), ")
    print(io, "$(is)=>$(os)")

    if mh.drop.active
        print(io, ", dropout=$(mh.drop.p))")
    else
        print(io, ")")
    end
end

function (mh::MultiheadAttention)(query::Abstract3DTensor{T},
                                  key::Abstract3DTensor{T},
                                  value::Abstract3DTensor{T};
                                  mask=nothing) where T
    qs = size(query)
    ks = size(key)
    vs = size(value)

    #size(ipq) == (h, q_seq_len, batch)
    ipq = @toNd mh.iqproj(query)
    ipk = @toNd mh.ikproj(key)
    ipv = @toNd mh.ivproj(value)

    h = size(ipq, 1)
    hs = div(h, mh.head)

    #size(ipq) == (hs, q_seq_len, head, batch)
    ipq = permutedims(reshape(ipq, hs, mh.head, qs[2], qs[3]), [1, 3, 2, 4])
    ipk = permutedims(reshape(ipk, hs, mh.head, ks[2], ks[3]), [1, 3, 2, 4])
    ipv = permutedims(reshape(ipv, hs, mh.head, vs[2], vs[3]), [1, 3, 2, 4])

    #size(ipq) == (hs, q_seq_len, head * batch)
    ipq = reshape(ipq, hs, qs[2], :)
    ipk = reshape(ipk, hs, ks[2], :)
    ipv = reshape(ipv, hs, vs[2], :)

    atten = attention(ipq,ipk,ipv;
                      mask=mask,
                      future=mh.future,
                      dropout=mh.drop)

    atten = permutedims(reshape(atten, hs, qs[2], mh.head, qs[3]), [1, 3, 2, 4]) #size(atten) == (hs, head, ql, b)
    atten = reshape(atten, h, qs[2], qs[3]) #size(atten) == (h, ql, b)

    out = @toNd mh.oproj(atten)
    out #size(out) == (h, q_seq_len, batch)
end

function (mh::MultiheadAttention)(query::AbstractMatrix{T},
                                  key::AbstractMatrix{T},
                                  value::AbstractMatrix{T};
                                  mask=nothing) where T
    # size(query) == (dims, seq_len)
    ipq = mh.iqproj(query)
    ipk = mh.ikproj(key)
    ipv = mh.ivproj(value)

    h = size(ipq)[1] #h == hs * head
    hs = div(h, mh.head)

    #size(hq) == (hs, seq_len, head)
    hq = permutedims(reshape(ipq, hs, mh.head, :), [1, 3, 2])
    hk = permutedims(reshape(ipk, hs, mh.head, :), [1, 3, 2])
    hv = permutedims(reshape(ipv, hs, mh.head, :), [1, 3, 2])

    atten = attention(hq, hk, hv;
                      mask=mask,
                      future=mh.future,
                      dropout=mh.drop)

    # size(atten) == (head*hs, seq_len)
    atten = reshape(permutedims(atten, [1, 3, 2]), h, :)

    mh.oproj(atten)
end

# unused function
# only for understand how attention works
# function attention(query::AbstractMatrix{T},
#                    key::AbstractMatrix{T},
#                    value::AbstractMatrix{T};
#                    mask=nothing, future::Bool = false,
#                    dropout=nothing) where T
#     # size(query) == (dims, {q,k}_seq_len) == size(key) == size(value)
#     # size(score) == (k_seq_len, q_seq_len)
#     dk = size(key)[1]
#     score = transpose(key) * query
#     score = score ./ convert(T, sqrt(dk))

#     if mask !== nothing
#         @. mask = (1 - mask) * convert(T, -1e9)
#         score = score .+ mask
#     end

#     if !future
#         fmask = tril!(fill!(similar(score), convert(T, -1e9)), -1)
#         score = score .+ fmask
#     end

#     score = softmax(score)
#     dropout !== nothing && (score = dropout(score))
#     value * score #size(return) == (dims, q_seq_len)
# end

function attention(query::Abstract3DTensor{T},
                   key::Abstract3DTensor{T},
                   value::Abstract3DTensor{T};
                   mask=nothing, future::Bool = false,
                   dropout=nothing) where T
    #size(query) == (dims, {q,k}_seq_len, batch) == size(key) == size(value)
    #size(score) == (k_seq_len, q_seq_len, batch)
    dk = size(key, 1)
    score = batchedmul(key, query; transA = true)
    score = score ./ convert(T, sqrt(dk))

    s = size(score)

    if mask !== nothing
        #weird issue on @. mask = (1 - mask) * -1e9 which casue mask to be -Inf
        mask = (1 .- mask) .* convert(T, -1e9)
        ms = size(mask)
        #score = score .+ mask; use broadcast instead of repeat mask for head
        score = reshape(reshape(score, s[1:end-1]..., :, ms[end]) .+ reshape(mask, ms[1:end-1]..., 1, ms[end]), s)
    end

    if !future
        #without ... will cause data move back to cpu
        fmask = tril!(fill!(similar(score, s[1:end-1]...), convert(T, -1e9)), -1)
        score = score .+ fmask
    end

    score = @toNd softmax(score) #reshape(softmax(reshape(score, s[1], :)) , s)
    dropout !== nothing && (score = dropout(score))
    batchedmul(value, score) #size(return) == (dims, q_seq_len, batch)
end
